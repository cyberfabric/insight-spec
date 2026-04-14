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
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $AIRBYTE_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body" "${AIRBYTE_API}${path}" 2>/dev/null)

  if [[ "$http_code" =~ ^2[0-9]{2}$ ]] || [[ "$http_code" == "404" ]]; then
    return 0
  else
    echo "    WARNING: API returned HTTP $http_code for ${path}, skipping state deletion" >&2
    return 1
  fi
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
        if _api_delete "/api/v1/connections/delete" "{\"connectionId\":\"$conn_id\"}"; then
          state_delete "tenants.$tenant.connectors.$connector.$source_id.connection_id"
        fi
      fi

      local src_id
      src_id=$(state_get "tenants.$tenant.connectors.$connector.$source_id.source_id")
      if [[ -n "$src_id" ]]; then
        echo "    Deleting source: $connector/$source_id ($src_id)"
        if _api_delete "/api/v1/sources/delete" "{\"sourceId\":\"$src_id\"}"; then
          state_delete "tenants.$tenant.connectors.$connector.$source_id.source_id"
        fi
      fi
    done
  done

  state_delete "tenants.$tenant"
  _state_sync_cm
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
      if _api_delete "/api/v1/destinations/delete" "{\"destinationId\":\"$dest_id\"}"; then
        state_delete "destinations.$dest"
      fi
    fi
  done
  state_delete "destinations"

  # Clear state
  echo "{}" > "$STATE_FILE"
  _state_sync_cm
  echo "  State cleared"
else
  cleanup_tenant "$MODE"
fi

echo "=== Cleanup done ==="
