#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# KUBECONFIG can be empty when running in-cluster

# Resolve shared Airbyte env
if [[ -z "${AIRBYTE_TOKEN:-}" ]]; then
  source ./scripts/resolve-airbyte-env.sh
fi

CONNECTIONS_DIR="./connections"
CONNECTORS_DIR="./connectors"

apply_tenant() {
  local tenant_config="$1"

  python3 - "$tenant_config" "$CONNECTORS_DIR" "$CONNECTIONS_DIR" \
    "${AIRBYTE_API:-http://localhost:8000}" "$AIRBYTE_TOKEN" "$WORKSPACE_ID" \
    "${CONNECTIONS_DIR}/.airbyte-state.yaml" <<'PYTHON'
import sys, os, json, yaml, urllib.request, urllib.error, pathlib

tenant_config_path, connectors_dir, connections_dir, airbyte_url, token, workspace_id, state_path = sys.argv[1:8]

# Load state
state = yaml.safe_load(open(state_path)) if os.path.exists(state_path) else {}
if not state: state = {}

def save_state():
    with open(state_path, "w") as f:
        yaml.dump(state, f, default_flow_style=False, sort_keys=False)
state_dir = os.path.join(connections_dir, ".state")
os.makedirs(state_dir, exist_ok=True)

# Derive state file name from config file name (not tenant_id)
config_basename = os.path.splitext(os.path.basename(tenant_config_path))[0]

# Load tenant config
with open(tenant_config_path) as f:
    tenant = yaml.safe_load(f)

tenant_id = tenant["tenant_id"]
dest_config = tenant.get("destination", {})
state_path = os.path.join(state_dir, f"{config_basename}.yaml")

# Load existing state
state = {}
if os.path.exists(state_path):
    with open(state_path) as f:
        state = yaml.safe_load(f) or {}

headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def api(method, path, data=None):
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(f"{airbyte_url}{path}", data=body, headers=headers, method=method)
    try:
        resp = urllib.request.urlopen(req)
        content = resp.read()
        return json.loads(content) if content else {}
    except urllib.error.HTTPError as e:
        err = e.read().decode()
        print(f"  API {e.code}: {err[:200]}", file=sys.stderr)
        return None

def find_or_create(resource_type, list_path, list_key, create_path, create_data, id_key, name_field, name_value):
    """Find existing resource by name or create new one."""
    existing = api("POST", list_path, {"workspaceId": workspace_id})
    if existing:
        for item in existing.get(list_key, []):
            if item.get("name") == name_value:
                print(f"  Found existing {resource_type}: {item[id_key]}")
                return item[id_key]

    result = api("POST", create_path, create_data)
    if result and id_key in result:
        print(f"  Created {resource_type}: {result[id_key]}")
        return result[id_key]

    print(f"  ERROR: could not create {resource_type}", file=sys.stderr)
    return None

# --- K8s Secret discovery ---
import subprocess, base64

def discover_secrets():
    """Discover Insight connector Secrets by label app.kubernetes.io/part-of=insight."""
    try:
        result = subprocess.run(
            ["kubectl", "get", "secrets", "-l", "app.kubernetes.io/part-of=insight",
             "--all-namespaces", "-o", "json"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            print(f"  WARNING: kubectl get secrets failed: {result.stderr.strip()}", file=sys.stderr)
            return []
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        print(f"  WARNING: kubectl not available or timed out: {e}", file=sys.stderr)
        return []

    secrets = []
    items = json.loads(result.stdout).get("items", [])
    for item in items:
        annotations = item.get("metadata", {}).get("annotations", {})
        connector = annotations.get("insight.cyberfabric.com/connector")
        source_id = annotations.get("insight.cyberfabric.com/source-id")
        if not connector:
            continue
        # Decode Secret data fields
        data = {}
        for k, v in item.get("data", {}).items():
            try:
                data[k] = base64.b64decode(v).decode()
            except Exception:
                data[k] = v
        secrets.append({
            "connector": connector,
            "source_id": source_id or connector,
            "data": data,
            "name": item["metadata"]["name"],
        })
    return secrets

def merge_credentials(secret_data, inline_config, tenant_id, source_id):
    """Merge K8s Secret data with inline tenant config. Inline takes precedence."""
    meta_fields = {"secretRef", "insight_source_id"}
    config = dict(secret_data)
    for k, v in (inline_config or {}).items():
        if k not in meta_fields:
            config[k] = v
    # Inject tenant/source IDs based on connector field naming conventions
    if "insight_tenant_id" not in config or config.get("insight_tenant_id") in ("", "${tenant_id}"):
        config["insight_tenant_id"] = tenant_id
    if "tenant_id" not in config or config.get("tenant_id") in ("", "${tenant_id}"):
        config["tenant_id"] = tenant_id
    config["insight_source_id"] = source_id
    if "source_instance_id" in secret_data or "source_instance_id" in (inline_config or {}):
        config["source_instance_id"] = source_id
    return config

# --- Lookup ClickHouse definition ID (shared across connectors) ---
ch_def_id = state.get("clickhouse_definition_id")
if not ch_def_id:
    defs = api("POST", "/api/v1/destination_definitions/list", {"workspaceId": workspace_id})
    if defs:
        for d in defs.get("destinationDefinitions", []):
            if "clickhouse" in d["name"].lower():
                ch_def_id = d["destinationDefinitionId"]
                break
if not ch_def_id:
    print("  ERROR: ClickHouse destination definition not found in Airbyte", file=sys.stderr)
    sys.exit(1)
state["clickhouse_definition_id"] = ch_def_id

# --- Shared ClickHouse destination (one for all connectors) ---
shared_dest_name = "clickhouse"
shared_dest_id = state.get("shared_destination_id")
if not shared_dest_id:
    existing = api("POST", "/api/v1/destinations/list", {"workspaceId": workspace_id})
    if existing:
        for d in existing.get("destinations", []):
            if d["name"] == shared_dest_name:
                shared_dest_id = d["destinationId"]
                print(f"  Shared destination found: {shared_dest_id}")
                break
if not shared_dest_id:
    result = api("POST", "/api/v1/destinations/create", {
        "workspaceId": workspace_id,
        "name": shared_dest_name,
        "destinationDefinitionId": ch_def_id,
        "connectionConfiguration": {
            "host": dest_config.get("host", "clickhouse.data.svc.cluster.local"),
            "port": str(dest_config.get("port", 8123)),
            "database": "default",
            "username": dest_config.get("username", "default"),
            "password": dest_config.get("password", "clickhouse"),
            "protocol": "http",
            "enable_json": True,
        }
    })
    if result and "destinationId" in result:
        shared_dest_id = result["destinationId"]
        print(f"  Shared destination created: {shared_dest_id}")
    else:
        print(f"  ERROR: could not create shared ClickHouse destination: {result}", file=sys.stderr)
        sys.exit(1)
state["shared_destination_id"] = shared_dest_id

# --- Discover K8s Secrets and build connector instances ---
state.setdefault("connectors", {})
conn_state_all = state["connectors"]

all_secrets = discover_secrets()
if all_secrets:
    print(f"  Discovered {len(all_secrets)} K8s Secret(s): {', '.join(s['name'] for s in all_secrets)}")
else:
    print(f"  No K8s Secrets found (label app.kubernetes.io/part-of=insight)")

# Group secrets by connector name
secrets_by_connector = {}
for s in all_secrets:
    secrets_by_connector.setdefault(s["connector"], []).append(s)

# Build list of (connector_name, source_id, config) to process
connector_instances = []
for connector_name, inline_creds in tenant.get("connectors", {}).items():
    matching_secrets = secrets_by_connector.get(connector_name, [])
    if matching_secrets:
        for secret in matching_secrets:
            sid = secret["source_id"]
            config = merge_credentials(secret["data"], inline_creds, tenant_id, sid)
            connector_instances.append((connector_name, sid, config))
            print(f"  Connector: {connector_name} (source: {sid}, from Secret '{secret['name']}')")
    elif inline_creds:
        # Backward compatibility: use inline credentials
        sid = inline_creds.get("insight_source_id", connector_name)
        config = merge_credentials({}, inline_creds, tenant_id, sid)
        connector_instances.append((connector_name, sid, config))
        print(f"  Connector: {connector_name} (source: {sid}, inline credentials)")
    else:
        print(f"  Connector: {connector_name} — ERROR: no K8s Secret and no inline credentials, skipping", file=sys.stderr)

# --- Per-connector sources + connections ---
for connector_name, source_id_label, config in connector_instances:

    # Find descriptor
    descriptor_path = None
    for p in pathlib.Path(connectors_dir).rglob("descriptor.yaml"):
        with open(p) as f:
            desc = yaml.safe_load(f)
        if desc.get("name") == connector_name:
            descriptor_path = p
            break

    if not descriptor_path:
        print(f"    SKIP: no descriptor for {connector_name}")
        continue

    with open(descriptor_path) as f:
        descriptor = yaml.safe_load(f)

    # State key includes source_id for multi-instance support
    state_key = f"{connector_name}-{source_id_label}" if source_id_label != connector_name else connector_name
    conn_state = state["connectors"].setdefault(state_key, {})

    # Create ClickHouse database for this connector's namespace
    db_name = descriptor.get("connection", {}).get("namespace", f"bronze_{connector_name}")
    print(f"    Creating database: {db_name}")
    os.system(f'kubectl exec -n data deploy/clickhouse -- clickhouse-client --password clickhouse --query "CREATE DATABASE IF NOT EXISTS {db_name}" 2>/dev/null')

    # Find source definition ID — from state first, then API fallback
    old_def_id = conn_state.get("definition_id")
    def_id = state.get("definitions", {}).get(connector_name)
    if def_id:
        print(f"    Definition from state: {def_id[:12]}...")
    else:
        # Fallback: search API (exact name match, latest if duplicates)
        defs = api("POST", "/api/v1/source_definitions/list", {"workspaceId": workspace_id})
        if defs:
            exact = [d["sourceDefinitionId"] for d in defs.get("sourceDefinitions", []) if d["name"] == connector_name]
            if exact:
                def_id = exact[-1]
                if len(exact) > 1:
                    print(f"    NOTE: {len(exact)} definitions named '{connector_name}', using latest")
            else:
                for d in defs.get("sourceDefinitions", []):
                    if d["name"].lower() == connector_name.lower():
                        def_id = d["sourceDefinitionId"]
                        break
    if not def_id:
        print(f"    SKIP: source definition not found for {connector_name} (run upload-manifests first)")
        continue
    conn_state["definition_id"] = def_id

    # Create/find source — recreate if definition changed
    source_name = f"{connector_name}-{source_id_label}-{tenant_id}"
    source_id = conn_state.get("source_id")
    source_recreated = False

    # Check if existing source uses outdated definition
    if source_id and old_def_id and old_def_id != def_id:
        print(f"    Definition changed ({old_def_id[:8]}→{def_id[:8]}), recreating source...")
        # Delete old connection first (depends on source)
        old_conn_id = conn_state.get("connection_id")
        if old_conn_id:
            api("POST", "/api/v1/connections/delete", {"connectionId": old_conn_id})
            conn_state.pop("connection_id", None)
        # Delete old source
        api("POST", "/api/v1/sources/delete", {"sourceId": source_id})
        source_id = None
        conn_state.pop("source_id", None)
        source_recreated = True

    if not source_id:
        source_id = find_or_create(
            "source",
            "/api/v1/sources/list", "sources",
            "/api/v1/sources/create",
            {
                "workspaceId": workspace_id,
                "name": source_name,
                "sourceDefinitionId": def_id,
                "connectionConfiguration": config,
            },
            "sourceId", "name", source_name
        )
    if not source_id:
        print(f"    ERROR: no source created for {connector_name}")
        continue
    conn_state["source_id"] = source_id

    # Create/find connection
    connection_config = descriptor.get("connection", {})
    connection_name = f"{connector_name}-{source_id_label}-to-clickhouse-{tenant_id}"
    connection_id = conn_state.get("connection_id")

    if not connection_id:
        configured_streams = connection_config.get("streams", [])
        configured_names = {s["name"] for s in configured_streams}

        # Discover real schema from source
        print(f"    Discovering schema from source...")
        discover_result = api("POST", "/api/v1/sources/discover_schema", {
            "sourceId": source_id,
            "disable_cache": True,
        })

        # Build catalog from discovered schema + configured streams
        sync_catalog = {"streams": []}
        if discover_result and "catalog" in discover_result:
            for entry in discover_result["catalog"].get("streams", []):
                # Discover returns {"stream": {...}, "config": {...}}
                stream_def = entry.get("stream", entry)
                stream_name = stream_def.get("name", "")
                # Include all streams if no explicit list, otherwise filter
                if configured_names and stream_name not in configured_names:
                    continue

                supported = stream_def.get("supportedSyncModes", ["full_refresh"])
                sync_mode = "incremental" if "incremental" in supported else "full_refresh"
                # Always use append_dedup — ClickHouse destination v2 NPEs on overwrite with no cursor
                dest_sync_mode = "append_dedup"

                stream_config = {
                    "syncMode": sync_mode,
                    "destinationSyncMode": dest_sync_mode,
                    "selected": True,
                }
                # Use source-defined primary key and cursor if available
                if stream_def.get("sourceDefinedPrimaryKey"):
                    stream_config["primaryKey"] = stream_def["sourceDefinedPrimaryKey"]
                if stream_def.get("defaultCursorField"):
                    stream_config["cursorField"] = stream_def["defaultCursorField"]

                sync_catalog["streams"].append({
                    "stream": stream_def,
                    "config": stream_config,
                })
                print(f"      Stream: {stream_name} ({sync_mode})")
        else:
            print(f"    WARNING: discover failed, creating connection without catalog")

        connection_id = find_or_create(
            "connection",
            "/api/v1/connections/list", "connections",
            "/api/v1/connections/create",
            {
                "sourceId": source_id,
                "destinationId": shared_dest_id,
                "name": connection_name,
                "namespaceDefinition": "customformat",
                "namespaceFormat": db_name,
                "status": "active",
                "syncCatalog": sync_catalog,
            },
            "connectionId", "name", connection_name
        )
    if connection_id:
        conn_state["connection_id"] = connection_id
        print(f"    Connection: {connection_id}")

# Save tenant state into .airbyte-state.yaml
state["workspace_id"] = workspace_id
for cn, cs in conn_state_all.items():
    for key in ("source_id", "connection_id"):
        if key in cs:
            section = key.replace("_id", "s")  # destination_id → destinations
            state.setdefault("tenants", {}).setdefault(tenant_id, {}).setdefault(section, {})[cn] = cs[key]
    if "definition_id" in cs:
        state.setdefault("definitions", {})[cn] = cs["definition_id"]

save_state()

# Sync ConfigMap if in-cluster
if os.path.exists("/var/run/secrets/kubernetes.io/serviceaccount/token"):
    os.system(f'kubectl create configmap airbyte-state --from-file=state.yaml={state_path} -n data --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null')

print(f"  State saved: {state_path}")
PYTHON
}

# --- Main ---
if [[ "${1:-}" == "--all" ]]; then
  for config_file in "${CONNECTIONS_DIR}"/*.yaml; do
    [[ -f "$config_file" ]] || continue
    tenant=$(basename "$config_file" .yaml)
    echo "  Applying connections for tenant: $tenant"
    apply_tenant "$config_file"
  done
else
  tenant="${1:?Usage: $0 <tenant_id> | --all}"
  config_file="${CONNECTIONS_DIR}/${tenant}.yaml"
  [[ -f "$config_file" ]] || { echo "ERROR: no config at ${config_file}" >&2; exit 1; }
  echo "  Applying connections for tenant: $tenant"
  apply_tenant "$config_file"
fi
