#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Reset a connector: delete Airbyte connection + source + definition,
# drop Bronze tables in ClickHouse, and clean state files.
#
# Usage:
#   ./airbyte-toolkit/reset-connector.sh <connector_name> <tenant>
#   ./airbyte-toolkit/reset-connector.sh github example-tenant
#
# Use when: schema breaking changes, pk migration, full re-sync needed.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

source ./airbyte-toolkit/lib/state.sh

CONNECTOR="${1:?Usage: $0 <connector_name> <tenant>}"
TENANT="${2:?Usage: $0 <connector_name> <tenant>}"

# Validate connector name (prevent SQL injection in DROP DATABASE)
if [[ ! "$CONNECTOR" =~ ^[a-z0-9_-]+$ ]]; then
  echo "ERROR: invalid connector name '${CONNECTOR}' (only lowercase alphanumeric, hyphens, underscores)" >&2
  exit 1
fi

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"

# Tenant key in state = filename stem (not tenant_id from inside YAML)
TENANT_KEY="$TENANT"

echo "=== Resetting connector: ${CONNECTOR} (tenant: ${TENANT_KEY}) ==="

# --- Resolve Airbyte env ---
if [[ -z "${AIRBYTE_TOKEN:-}" ]]; then
  source ./airbyte-toolkit/lib/env.sh
fi

# --- Read state ---
STATE_FILE="./airbyte-toolkit/state.yaml"

python3 - "$CONNECTOR" "$TENANT_KEY" "$AIRBYTE_API" "$AIRBYTE_TOKEN" \
  "$STATE_FILE" <<'PYTHON'
import sys, os, json, yaml, urllib.request, urllib.error, subprocess, base64

connector, tenant_id, airbyte_url, token, state_path = sys.argv[1:6]
headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def api(path, data):
    body = json.dumps(data).encode()
    req = urllib.request.Request(f"{airbyte_url}{path}", data=body, headers=headers, method="POST")
    try:
        urllib.request.urlopen(req)
        return True
    except urllib.error.HTTPError as e:
        code = e.code
        if code == 404:
            return True  # already gone
        print(f"  API {code}: {e.read().decode()[:200]}", file=sys.stderr)
        return False

# Load state
state = {}
if os.path.exists(state_path):
    with open(state_path) as f:
        state = yaml.safe_load(f) or {}

# Read tenant connectors from hierarchical state:
#   tenants.<tenant>.connectors.<connector>.<source_id>.{source_id, connection_id}
tenant_connectors = state.get("tenants", {}).get(tenant_id, {}).get("connectors", {}).get(connector, {})

if not tenant_connectors:
    print(f"  No state entries found for connector '{connector}' in tenant '{tenant_id}'")

for source_key, entry in list(tenant_connectors.items()):
    # Delete connection
    conn_id = entry.get("connection_id")
    if conn_id:
        print(f"  Deleting connection: {conn_id}")
        api("/api/v1/connections/delete", {"connectionId": conn_id})

    # Delete source
    source_id = entry.get("source_id")
    if source_id:
        print(f"  Deleting source: {source_id}")
        api("/api/v1/sources/delete", {"sourceId": source_id})

    print(f"  Removed state entry: {connector}/{source_key}")

# Delete definition (definitions.<connector>.id)
def_id = state.get("definitions", {}).get(connector, {}).get("id")
if def_id:
    print(f"  Deleting definition: {def_id}")
    api("/api/v1/source_definitions/delete", {"sourceDefinitionId": def_id})

# Clean tenant-level connector state
tenant_data = state.get("tenants", {}).get(tenant_id, {}).get("connectors", {})
if connector in tenant_data:
    del tenant_data[connector]

# Clean definitions
defs = state.get("definitions", {})
keys_to_remove = [k for k in defs if k == connector or k.startswith(f"{connector}-")]
for k in keys_to_remove:
    del defs[k]

# Save state
with open(state_path, "w") as f:
    yaml.dump(state, f, default_flow_style=False, sort_keys=False)
print(f"  State cleaned: {state_path}")

# --- Drop Bronze tables ---
# Resolve ClickHouse password
ch_pass = os.environ.get("CLICKHOUSE_PASSWORD", "")
if not ch_pass:
    result = subprocess.run(
        ["kubectl", "get", "secret", "clickhouse-credentials", "-n", "data",
         "-o", "jsonpath={.data.password}"],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode == 0 and result.stdout.strip():
        ch_pass = base64.b64decode(result.stdout.strip()).decode()

db_name = f"bronze_{connector}"
if ch_pass:
    print(f"  Dropping Bronze database: {db_name}")
    result = subprocess.run(
        ["kubectl", "exec", "-n", "data", "deploy/clickhouse", "--",
         "clickhouse-client", "--password", ch_pass,
         "--query", f"DROP DATABASE IF EXISTS {db_name}"],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode == 0:
        print(f"  Database dropped: {db_name}")
    else:
        print(f"  WARN: drop failed: {result.stderr.strip()}", file=sys.stderr)
else:
    print(f"  SKIP: no ClickHouse password, cannot drop {db_name}")
PYTHON

# Note: all state is now managed in a single file (airbyte-toolkit/state.yaml),
# already cleaned by the Python block above.

echo ""
echo "=== Reset complete: ${CONNECTOR} ==="
echo ""
echo "  To recreate:"
echo "    ./airbyte-toolkit/build-connector.sh <path>     # CDK only"
echo "    ./airbyte-toolkit/register.sh <path>    # nocode only"
echo "    ./airbyte-toolkit/connect.sh ${TENANT}"
echo "    ./run-sync.sh ${CONNECTOR} ${TENANT}"
