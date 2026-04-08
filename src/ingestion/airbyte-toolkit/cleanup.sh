#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Airbyte Toolkit — Cleanup resources
#
# Deletes all Airbyte resources tracked in state and clears the state file.
# Usage: ./cleanup.sh [--all | tenant_name]
# ---------------------------------------------------------------------------

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$TOOLKIT_DIR/lib/env.sh"
source "$TOOLKIT_DIR/lib/state.sh"

MODE="${1:---all}"

_api_delete() {
  local path="$1" body="$2"
  curl -sf -X POST -H "Authorization: Bearer $AIRBYTE_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body" "${AIRBYTE_API}${path}" >/dev/null 2>&1 || true
}

cleanup_tenant() {
  local tenant="$1"
  echo "  Cleaning tenant: $tenant"

  for connector in $(state_list "tenants.$tenant.connectors"); do
    for source_id in $(state_list "tenants.$tenant.connectors.$connector"); do
      local conn_id
      conn_id=$(state_get "tenants.$tenant.connectors.$connector.$source_id.connection_id")
      if [[ -n "$conn_id" ]]; then
        echo "    Deleting connection: $connector/$source_id ($conn_id)"
        _api_delete "/api/v1/connections/delete" "{\"connectionId\":\"$conn_id\"}"
      fi

      local src_id
      src_id=$(state_get "tenants.$tenant.connectors.$connector.$source_id.source_id")
      if [[ -n "$src_id" ]]; then
        echo "    Deleting source: $connector/$source_id ($src_id)"
        _api_delete "/api/v1/sources/delete" "{\"sourceId\":\"$src_id\"}"
      fi
    done
  done

  state_delete "tenants.$tenant"
}

echo "=== Airbyte Toolkit: Cleanup ==="

if [[ "$MODE" == "--all" ]]; then
  # Delete all tenant resources
  for tenant in $(state_list "tenants"); do
    cleanup_tenant "$tenant"
  done

  # Delete destinations
  for dest in $(state_list "destinations"); do
    dest_id=$(state_get "destinations.$dest.id")
    if [[ -n "$dest_id" ]]; then
      echo "  Deleting destination: $dest ($dest_id)"
      _api_delete "/api/v1/destinations/delete" "{\"destinationId\":\"$dest_id\"}"
    fi
  done
  state_delete "destinations"

  # Clear state
  echo "{}" > "$STATE_FILE"
  echo "  State cleared"
else
  cleanup_tenant "$MODE"
fi

echo "=== Cleanup done ==="
