#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Updating connectors ==="

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"
export TOOLKIT_DIR="${SCRIPT_DIR}/airbyte-toolkit"

"${TOOLKIT_DIR}/register.sh" --all

echo "=== Done ==="
