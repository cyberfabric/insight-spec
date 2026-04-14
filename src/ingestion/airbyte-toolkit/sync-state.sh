#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Airbyte Toolkit — Sync state from Airbyte API
#
# Rebuilds state.yaml from current Airbyte resources.
# Usage: ./sync-state.sh
# ---------------------------------------------------------------------------

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INGESTION_DIR="$(cd "$TOOLKIT_DIR/.." && pwd)"

source "$TOOLKIT_DIR/lib/env.sh"
source "$TOOLKIT_DIR/lib/state.sh"

echo "Syncing state from Airbyte API..."

state_set "workspace_id" "$WORKSPACE_ID"

python3 - "$AIRBYTE_API" "$AIRBYTE_TOKEN" "$WORKSPACE_ID" "$STATE_FILE" "$INGESTION_DIR" <<'PY'
import sys, json, yaml, urllib.request, urllib.error, os, glob

airbyte_url, token, workspace_id, state_file, ingestion_dir = sys.argv[1:6]
headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def api(path, data):
    body = json.dumps(data).encode()
    req = urllib.request.Request(f"{airbyte_url}{path}", data=body, headers=headers, method="POST")
    try:
        return json.loads(urllib.request.urlopen(req).read())
    except urllib.error.HTTPError as e:
        print(f"ERROR: API call {path} failed with HTTP {e.code}: {e.read().decode()[:200]}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"ERROR: API call {path} failed: {e.reason}", file=sys.stderr)
        sys.exit(1)

# Load or init state
data = yaml.safe_load(open(state_file)) if os.path.exists(state_file) else {}
if not data: data = {}
data["workspace_id"] = workspace_id

# --- Definitions ---
defs = api("/api/v1/source_definitions/list", {"workspaceId": workspace_id})
definitions = {}
for d in defs.get("sourceDefinitions", []):
    name = d["name"]
    if name == name.lower() and not name.startswith("source-"):
        definitions[name] = {"id": d["sourceDefinitionId"]}
data["definitions"] = definitions
print(f"  Definitions: {len(definitions)} ({', '.join(definitions.keys())})")

# --- Destinations ---
dests = api("/api/v1/destinations/list", {"workspaceId": workspace_id})
destinations = {}
for i, d in enumerate(dests.get("destinations", [])):
    # Use stable key "clickhouse" for the first destination, avoid dependency on UI display name
    key = "clickhouse" if i == 0 else f"dest-{i}"
    entry = {"id": d["destinationId"]}
    if "destinationDefinitionId" in d:
        entry["definition_id"] = d["destinationDefinitionId"]
    destinations[key] = entry
data["destinations"] = destinations
print(f"  Destinations: {len(destinations)}")

# --- Build tenant → connector → source_id mapping from naming convention ---
# Source names: {connector}-{source_id}-{tenant_id}
# Connection names: {connector}-{source_id}-to-clickhouse-{tenant_id}
tenants = {}

sources = api("/api/v1/sources/list", {"workspaceId": workspace_id})
for s in sources.get("sources", []):
    name = s["name"]
    # Parse: {connector}-{source_id}-{tenant}
    # Strategy: try to match known connector names from definitions
    matched = False
    for conn_name in sorted(definitions.keys(), key=len, reverse=True):
        prefix = f"{conn_name}-"
        if name.startswith(prefix):
            rest = name[len(prefix):]
            # rest = {source_id}-{tenant}
            # Find tenant by checking connection configs
            for tenant_file in glob.glob(os.path.join(ingestion_dir, "connections", "*.yaml")):
                basename = os.path.basename(tenant_file).replace(".yaml", "")
                if basename.startswith(".") or basename.endswith(".example"):
                    continue
                tenant_cfg = yaml.safe_load(open(tenant_file)) or {}
                tenant_id = tenant_cfg.get("tenant_id", basename)
                # Tenant ID in Airbyte source name uses underscore
                tenant_id_variants = [tenant_id, tenant_id.replace("-", "_"), basename, basename.replace("-", "_")]
                for tv in tenant_id_variants:
                    suffix = f"-{tv}"
                    if rest.endswith(suffix):
                        source_id = rest[:len(rest)-len(suffix)]
                        t = tenants.setdefault(basename, {"connectors": {}})
                        c = t["connectors"].setdefault(conn_name, {})
                        c[source_id] = {"source_id": s["sourceId"]}
                        print(f"  Source: {name} → tenants.{basename}.connectors.{conn_name}.{source_id}")
                        matched = True
                        break
                if matched:
                    break
            if matched:
                break
    if not matched:
        print(f"  Source: {name} → UNMATCHED (skipped)")

# --- Connections ---
conns = api("/api/v1/connections/list", {"workspaceId": workspace_id})
for c in conns.get("connections", []):
    name = c["name"]
    # Parse: {connector}-{source_id}-to-clickhouse-{tenant}
    if "-to-clickhouse-" not in name:
        continue
    left, right = name.split("-to-clickhouse-", 1)
    # left = {connector}-{source_id}, right = {tenant_id}
    # Match tenant
    for basename, t in tenants.items():
        tenant_cfg_path = os.path.join(ingestion_dir, "connections", f"{basename}.yaml")
        if not os.path.exists(tenant_cfg_path):
            continue
        tenant_cfg = yaml.safe_load(open(tenant_cfg_path)) or {}
        tenant_id = tenant_cfg.get("tenant_id", basename)
        tenant_id_variants = [tenant_id, tenant_id.replace("-", "_"), basename, basename.replace("-", "_")]
        if right not in tenant_id_variants:
            continue
        # Match connector + source_id from left part
        for conn_name, sources_map in t["connectors"].items():
            prefix = f"{conn_name}-"
            if left.startswith(prefix):
                source_id = left[len(prefix):]
                if source_id in sources_map:
                    sources_map[source_id]["connection_id"] = c["connectionId"]
                    print(f"  Connection: {name} → tenants.{basename}.connectors.{conn_name}.{source_id}")
                    break

data["tenants"] = {k: v for k, v in tenants.items()}

# Write state
with open(state_file, "w") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
print(f"\nState saved: {state_file}")
PY

# Sync state file to ConfigMap (in-cluster)
_state_sync_cm

echo "Done."
