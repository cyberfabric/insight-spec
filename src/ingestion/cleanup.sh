#!/usr/bin/env bash
# Clean ingestion state only. For full cluster cleanup, use the root cleanup.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Cleaning ingestion state ==="

# Clean Airbyte toolkit state
rm -f airbyte-toolkit/state.yaml 2>/dev/null || true

# Clean generated tenant workflows (preserve templates/ and schedules/)
for d in workflows/*/; do
  case "$(basename "$d")" in templates|schedules) continue;; esac
  rm -rf "$d" 2>/dev/null || true
done

echo "=== Ingestion state cleaned ==="
echo "  For full cluster cleanup: $(cd "$SCRIPT_DIR/../.." && pwd)/cleanup.sh"
