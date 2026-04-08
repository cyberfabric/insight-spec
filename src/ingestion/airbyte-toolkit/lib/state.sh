#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Airbyte Toolkit — State library
#
# Single state file: airbyte-toolkit/state.yaml
# In-cluster mirror: ConfigMap airbyte-state in namespace data
#
# Usage:
#   source airbyte-toolkit/lib/state.sh
#   state_get "definitions.m365.id"
#   state_set "definitions.m365.id" "abc-123"
#   state_delete "definitions.m365"
#   state_list "tenants.example-tenant.connectors"
#   state_dump
# ---------------------------------------------------------------------------

TOOLKIT_DIR="${TOOLKIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_FILE="${TOOLKIT_DIR}/state.yaml"
STATE_CM_NAME="airbyte-state"
STATE_CM_NS="data"

_state_in_cluster() {
  [[ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]]
}

_state_init() {
  if _state_in_cluster; then
    kubectl get configmap "$STATE_CM_NAME" -n "$STATE_CM_NS" >/dev/null 2>&1 || \
      kubectl create configmap "$STATE_CM_NAME" -n "$STATE_CM_NS" --from-literal=state.yaml="{}" 2>/dev/null
  fi
  [[ -f "$STATE_FILE" ]] || echo "{}" > "$STATE_FILE"
}

_state_sync_cm() {
  if _state_in_cluster; then
    kubectl create configmap "$STATE_CM_NAME" -n "$STATE_CM_NS" \
      --from-file=state.yaml="$STATE_FILE" --dry-run=client -o yaml | \
      kubectl apply -f - >/dev/null 2>&1
  fi
}

_state_src() {
  if _state_in_cluster; then
    local tmp="/tmp/_airbyte_state.yaml"
    kubectl get configmap "$STATE_CM_NAME" -n "$STATE_CM_NS" \
      -o jsonpath='{.data.state\.yaml}' > "$tmp" 2>/dev/null || echo "{}" > "$tmp"
    echo "$tmp"
  else
    echo "$STATE_FILE"
  fi
}

# state_get <dotpath>
# e.g. state_get "definitions.m365.id" → "abc-123"
state_get() {
  local path="$1"
  _state_init
  python3 -c "
import yaml, sys
d = yaml.safe_load(open('$(_state_src)')) or {}
for k in '$path'.split('.'):
    if isinstance(d, dict):
        d = d.get(k, '')
    else:
        d = ''
        break
print(d if isinstance(d, str) else '')
"
}

# state_set <dotpath> <value>
# e.g. state_set "definitions.m365.id" "abc-123"
state_set() {
  local path="$1" value="$2"
  _state_init
  python3 - "$STATE_FILE" "$path" "$value" <<'PY'
import sys, yaml, os
state_file, path, value = sys.argv[1], sys.argv[2], sys.argv[3]
data = yaml.safe_load(open(state_file)) if os.path.exists(state_file) and os.path.getsize(state_file) > 0 else {}
if not data: data = {}
keys = path.split(".")
d = data
for k in keys[:-1]:
    d = d.setdefault(k, {})
d[keys[-1]] = value
with open(state_file, "w") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
PY
  _state_sync_cm
}

# state_delete <dotpath>
# e.g. state_delete "tenants.old-tenant"
state_delete() {
  local path="$1"
  _state_init
  python3 - "$STATE_FILE" "$path" <<'PY'
import sys, yaml, os
state_file, path = sys.argv[1], sys.argv[2]
data = yaml.safe_load(open(state_file)) if os.path.exists(state_file) and os.path.getsize(state_file) > 0 else {}
if not data: data = {}
keys = path.split(".")
d = data
for k in keys[:-1]:
    if isinstance(d, dict) and k in d:
        d = d[k]
    else:
        sys.exit(0)
if isinstance(d, dict) and keys[-1] in d:
    del d[keys[-1]]
with open(state_file, "w") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
PY
  _state_sync_cm
}

# state_list <dotpath>
# Returns keys of the map at path, one per line
# e.g. state_list "tenants.example-tenant.connectors" → "m365\nzoom\nbamboohr"
state_list() {
  local path="$1"
  _state_init
  python3 -c "
import yaml
d = yaml.safe_load(open('$(_state_src)')) or {}
for k in '$path'.split('.'):
    if isinstance(d, dict):
        d = d.get(k, {})
    else:
        d = {}
        break
if isinstance(d, dict):
    for k in d:
        print(k)
"
}

# state_dump — print full state YAML
state_dump() {
  _state_init
  cat "$(_state_src)" 2>/dev/null
}
