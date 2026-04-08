#!/usr/bin/env bash
# Deploy ingestion services: Airbyte, ClickHouse, Argo Workflows.
# Expects KUBECONFIG to be set by the caller (root up.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-insight-toolbox:local}"

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "ERROR: KUBECONFIG is not set. Run the root up.sh instead." >&2
  exit 1
fi

echo "=== Ingestion: deploying services ==="

# --- Prerequisites ---
for cmd in kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not found" >&2
    exit 1
  fi
done

# --- Namespaces ---
echo "  Creating namespaces..."
for ns in airbyte argo data; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# --- Build toolbox image ---
echo "  Building toolbox image..."
TOOLBOX_IMAGE="$TOOLBOX_IMAGE" ./tools/toolbox/build.sh

# --- Secret checks ---
MISSING=()

has_secret() {
  kubectl get secret "$1" -n "$2" &>/dev/null
}

# --- Airbyte ---
echo "  Deploying Airbyte..."
helm repo add airbyte https://airbytehq.github.io/helm-charts 2>/dev/null || true
helm repo update airbyte
kubectl scale statefulset -n airbyte --all --replicas=1 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=db -n airbyte --timeout=60s 2>/dev/null || true
kubectl delete pod airbyte-airbyte-bootloader -n airbyte --force --grace-period=0 2>/dev/null || true
helm upgrade --install airbyte airbyte/airbyte \
  --namespace airbyte \
  --values "k8s/airbyte/values-${ENV:-local}.yaml" \
  --wait --timeout 10m
kubectl scale deployment -n airbyte --all --replicas=1 2>/dev/null || true
kubectl scale statefulset -n airbyte --all --replicas=1 2>/dev/null || true

# --- Copy Airbyte auth secret to argo namespace ---
echo "  Syncing Airbyte auth secret to argo namespace..."
if kubectl get secret airbyte-auth-secrets -n airbyte &>/dev/null; then
  kubectl get secret airbyte-auth-secrets -n airbyte -o json \
    | python3 -c "import sys,json; s=json.load(sys.stdin); print(json.dumps({'apiVersion':'v1','kind':'Secret','type':'Opaque','metadata':{'name':'airbyte-auth-secrets','namespace':'argo'},'data':s['data']}))" \
    | kubectl apply -f -
else
  echo "  WARNING: airbyte-auth-secrets not found in airbyte namespace (Airbyte may still be starting)"
fi

# --- ClickHouse ---
if has_secret clickhouse-credentials data; then
  echo "  Deploying ClickHouse..."
  kubectl apply -f k8s/clickhouse/
  kubectl scale deployment/clickhouse -n data --replicas=1 2>/dev/null || true
else
  echo "  SKIP: ClickHouse — Secret 'clickhouse-credentials' not found in namespace 'data'"
  echo "    Create it:"
  echo "      kubectl create secret generic clickhouse-credentials -n data --from-literal=password='YOUR_PASSWORD'"
  echo "    Or: ./secrets/apply.sh"
  MISSING+=("clickhouse-credentials (namespace: data)")
fi

# --- Argo Workflows ---
echo "  Deploying Argo Workflows..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo
helm upgrade --install argo-workflows argo/argo-workflows \
  --namespace argo \
  --values "k8s/argo/values-${ENV:-local}.yaml" \
  --wait --timeout 5m
kubectl scale deployment -n argo --all --replicas=1 2>/dev/null || true

# --- Argo RBAC + WorkflowTemplates ---
echo "  Applying Argo RBAC..."
kubectl apply -f k8s/argo/rbac.yaml
echo "  Applying WorkflowTemplates..."
kubectl apply -f workflows/templates/

# --- Wait for services ---
echo "  Waiting for services..."
if has_secret clickhouse-credentials data; then
  kubectl wait --for=condition=ready pod -l app=clickhouse -n data --timeout=120s
fi
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argo-workflows-server -n argo --timeout=120s

# --- Report ---
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo ""
  echo "  Missing secrets:"
  for m in "${MISSING[@]}"; do
    echo "    - $m"
  done
  echo "  Create them and re-run."
fi

echo "=== Ingestion: done ==="
