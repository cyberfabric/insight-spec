#!/usr/bin/env bash
# Stop ingestion services (data preserved).
# Expects KUBECONFIG to be set by the caller (root down.sh).
set -euo pipefail

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "ERROR: KUBECONFIG is not set. Run the root down.sh instead." >&2
  exit 1
fi

echo "=== Ingestion: stopping services (data preserved) ==="

# Stop Argo workflows
echo "  Stopping Argo workflows..."
kubectl scale deployment -n argo --all --replicas=0 2>/dev/null || true

# Stop ClickHouse
echo "  Stopping ClickHouse..."
kubectl scale deployment/clickhouse -n data --replicas=0 2>/dev/null || true

# Stop Airbyte
echo "  Stopping Airbyte..."
kubectl scale deployment -n airbyte --all --replicas=0 2>/dev/null || true
kubectl scale statefulset -n airbyte --all --replicas=0 2>/dev/null || true

echo "=== Ingestion: stopped ==="
