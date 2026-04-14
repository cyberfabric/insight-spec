#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TENANT="${1:-}"
echo "=== Updating connections ==="

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"
export TOOLKIT_DIR="${SCRIPT_DIR}/airbyte-toolkit"

ARGS="${TENANT:---all}"
"${TOOLKIT_DIR}/connect.sh" ${ARGS}

echo "=== Done ==="
