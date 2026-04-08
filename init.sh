#!/usr/bin/env bash
# Insight platform — initialize after cluster is up.
#
# This script:
#   1. Verifies the cluster is reachable
#   2. Guides through secret creation if missing
#   3. Applies secrets
#   4. Deploys ClickHouse (if skipped during up.sh)
#   5. Runs ingestion init (databases, connectors, connections, workflows)
#
# Prerequisites: ./up.sh must have been run first.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"
export KUBECONFIG="${KUBECONFIG_PATH}"

echo "=== Insight Platform — Initialize ==="

# --- Verify cluster ---
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: Cannot reach cluster. Run ./up.sh first." >&2
  exit 1
fi

# --- Check and guide secrets ---
SECRETS_DIR="$ROOT_DIR/src/ingestion/secrets"
MISSING_SECRETS=()

check_secret_file() {
  local file="$1"
  local example="$2"
  local label="$3"
  if [[ ! -f "$file" ]]; then
    MISSING_SECRETS+=("$label: cp $example $file")
  fi
}

check_secret_file "$SECRETS_DIR/clickhouse.yaml" "$SECRETS_DIR/clickhouse.yaml.example" "ClickHouse"

shopt -s nullglob
for example in "$SECRETS_DIR"/connectors/*.yaml.example; do
  base="$(basename "$example" .yaml.example)"
  target="$SECRETS_DIR/connectors/${base}.yaml"
  check_secret_file "$target" "$example" "Connector: $base"
done
shopt -u nullglob

if [[ ${#MISSING_SECRETS[@]} -gt 0 ]]; then
  echo ""
  echo "  Missing secret files (copy examples and fill in credentials):"
  echo ""
  for m in "${MISSING_SECRETS[@]}"; do
    echo "    $m"
  done
  echo ""
  echo "  After creating the files, re-run: ./init.sh"
  exit 1
fi

# --- Apply secrets ---
echo "=== Applying secrets ==="
"$SECRETS_DIR/apply.sh"

# --- Deploy ClickHouse if it was skipped ---
if ! kubectl get deployment clickhouse -n data &>/dev/null; then
  echo "=== Deploying ClickHouse (was skipped during up.sh) ==="
  kubectl apply -f src/ingestion/k8s/clickhouse/
  kubectl wait --for=condition=ready pod -l app=clickhouse -n data --timeout=120s
fi

# --- Run ingestion init ---
echo "=== Running ingestion init ==="
cd "$ROOT_DIR/src/ingestion"
./run-init.sh

echo ""
echo "════════════════════════════════════════════════"
echo "  Initialization complete!"
echo ""
echo "  Services:"
echo "    Frontend:   http://localhost:8000"
echo "    API:        http://localhost:8000/api/v1"
echo "    Airbyte:    http://localhost:8001"
echo "    Argo UI:    http://localhost:30500"
echo "    ClickHouse: http://localhost:30123"
AIRBYTE_EMAIL=$(kubectl get secret airbyte-auth-secrets -n airbyte -o jsonpath='{.data.instance-admin-email}' 2>/dev/null | base64 -d 2>/dev/null) || true
AIRBYTE_PASS=$(kubectl get secret airbyte-auth-secrets -n airbyte -o jsonpath='{.data.instance-admin-password}' 2>/dev/null | base64 -d 2>/dev/null) || true
if [[ -n "$AIRBYTE_PASS" ]]; then
  echo ""
  echo "  Airbyte UI login:"
  echo "    Email:    ${AIRBYTE_EMAIL:-admin@example.com}"
  echo "    Password: ${AIRBYTE_PASS}"
fi
echo ""
echo "  Run a sync:"
echo "    cd src/ingestion && ./run-sync.sh <connector> <tenant>"
echo "════════════════════════════════════════════════"
