#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TENANT="${1:-}"
echo "=== Updating workflows ==="

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"

ARGS="${TENANT:---all}"
./scripts/sync-flows.sh ${ARGS}

echo "=== Done ==="
