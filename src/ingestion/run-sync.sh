#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONNECTOR="${1:?Usage: $0 <connector> <tenant_id>}"
TENANT="${2:?Usage: $0 <connector> <tenant_id>}"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kind-ingestion}"

# Read connection_id from local state or K8s ConfigMap
STATE_FILE="connections/.state/${TENANT}.yaml"
if [[ -f "$STATE_FILE" ]]; then
  CONNECTION_ID=$(yq -r ".connectors.${CONNECTOR}.connection_id // empty" "$STATE_FILE")
else
  CONNECTION_ID=$(kubectl get configmap "connection-state-${TENANT}" -n data -o jsonpath='{.data.state\.yaml}' 2>/dev/null \
    | yq -r ".connectors.${CONNECTOR}.connection_id // empty" 2>/dev/null)
fi
[[ -n "$CONNECTION_ID" ]] || { echo "ERROR: no connection_id for connector '$CONNECTOR' tenant '$TENANT'" >&2; exit 1; }

DBT_SELECT=$(find connectors -name descriptor.yaml -exec grep -l "name: ${CONNECTOR}" {} \; | head -1 | xargs yq -r '.dbt_select // "+tag:silver"' 2>/dev/null)

echo "Running sync: ${CONNECTOR} / ${TENANT}"
echo "  connection_id: ${CONNECTION_ID}"
echo "  dbt_select: ${DBT_SELECT}"

kubectl create -n argo -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: ${CONNECTOR}-${TENANT}-
  namespace: argo
  labels:
    tenant: "${TENANT}"
    connector: "${CONNECTOR}"
spec:
  entrypoint: run
  templates:
    - name: run
      steps:
        - - name: pipeline
            templateRef:
              name: ingestion-pipeline
              template: pipeline
            arguments:
              parameters:
                - name: connection_id
                  value: "${CONNECTION_ID}"
                - name: dbt_select
                  value: "${DBT_SELECT}"
EOF

echo "Workflow submitted. Monitor at http://localhost:30500 or:"
echo "  kubectl get workflows -n argo -l connector=${CONNECTOR},tenant=${TENANT}"
