#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Show logs for a workflow run
#
# Usage:
#   ./logs.sh <workflow-name>                      # all logs (completed)
#   ./logs.sh <workflow-name> sync                 # only sync step
#   ./logs.sh <workflow-name> dbt                  # only dbt step
#   ./logs.sh -f <workflow-name|latest>            # follow live
#   ./logs.sh latest                               # latest workflow
# ---------------------------------------------------------------------------

KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kind-ingestion}"
export KUBECONFIG

FOLLOW=""
if [[ "${1:-}" == "-f" ]]; then
  FOLLOW="true"
  shift
fi

workflow="${1:-}"
step="${2:-}"

if [[ -z "$workflow" ]]; then
  echo "Usage: $0 [-f] <workflow-name|latest> [sync|dbt|all]" >&2
  echo "" >&2
  echo "  -f    Follow logs in real time" >&2
  echo "" >&2
  echo "Recent workflows:" >&2
  kubectl get workflows -n argo --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | tail -5 | awk '{print "  " $1 "  " $2 "  " $4}' >&2
  exit 1
fi

if [[ "$workflow" == "latest" ]]; then
  workflow=$(kubectl get workflows -n argo --sort-by=.metadata.creationTimestamp --no-headers | tail -1 | awk '{print $1}')
  if [[ -z "$workflow" ]]; then
    echo "No workflows found" >&2
    exit 1
  fi
  echo "Latest workflow: $workflow" >&2
fi

SELECTOR="workflows.argoproj.io/workflow=$workflow"

echo "=== Workflow: $workflow ===" >&2
kubectl get workflow "$workflow" -n argo --no-headers 2>/dev/null | awk '{print "Status: " $2 "  Age: " $4}' >&2
echo "" >&2

# --- Static mode: dump all logs from completed pods ---
if [[ -z "$FOLLOW" ]]; then
  # Argo workflow pods
  pods=$(kubectl get pods -n argo -l "$SELECTOR" --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | awk '{print $1}')
  for pod in $pods; do
    case "${step}" in
      sync|trigger) echo "$pod" | grep -qE "trigger-sync|poll-job" || continue ;;
      dbt|run)      echo "$pod" | grep -q "run-" || continue ;;
      ""|all)       ;;
      *)            echo "Unknown step: $step" >&2; exit 1 ;;
    esac
    echo "--- argo/$pod ---" >&2
    kubectl logs "$pod" -n argo -c main 2>/dev/null || true
  done

  # Airbyte replication pods (sync step runs Airbyte jobs)
  if [[ "${step}" != "dbt" && "${step}" != "run" ]]; then
    repl_pods=$(kubectl get pods -n airbyte -l "airbyte.io/sync-job-id" --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | awk '{print $1}')
    for pod in $repl_pods; do
      echo "--- airbyte/$pod (orchestrator) ---" >&2
      kubectl logs "$pod" -n airbyte -c orchestrator 2>/dev/null | tail -50 || true
      echo "--- airbyte/$pod (source) ---" >&2
      kubectl logs "$pod" -n airbyte -c source 2>/dev/null | tail -30 || true
      echo "--- airbyte/$pod (destination) ---" >&2
      kubectl logs "$pod" -n airbyte -c destination 2>/dev/null | tail -30 || true
    done
  fi

  exit 0
fi

# --- Follow mode: tail logs from running/new pods ---
echo "Following logs (Ctrl+C to stop)..." >&2

SEEN_PODS=""
while true; do
  # Check workflow status
  phase=$(kubectl get workflow "$workflow" -n argo -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

  # Get all pods for this workflow
  pods=$(kubectl get pods -n argo -l "$SELECTOR" --no-headers 2>/dev/null | awk '{print $1, $3}')

  while IFS=' ' read -r pod status; do
    [[ -z "$pod" ]] && continue

    # Filter by step
    case "${step}" in
      sync|trigger) echo "$pod" | grep -qE "trigger-sync|poll-job" || continue ;;
      dbt|run)      echo "$pod" | grep -q "run-" || continue ;;
      ""|all)       ;;
    esac

    # Skip already seen pods
    echo "$SEEN_PODS" | grep -q "$pod" && continue
    SEEN_PODS="$SEEN_PODS $pod"

    # Wait for container to be ready
    if [[ "$status" == *"Init"* || "$status" == "Pending" || "$status" == "ContainerCreating" ]]; then
      echo "[$pod] Waiting for container..." >&2
      kubectl wait --for=condition=Ready pod/"$pod" -n argo --timeout=120s 2>/dev/null || true
    fi

    # Stream logs in background
    echo "--- $pod ---" >&2
    if [[ "$status" == "Completed" || "$status" == "Error" ]]; then
      kubectl logs "$pod" -n argo -c main 2>/dev/null || true
    else
      kubectl logs "$pod" -n argo -c main -f 2>/dev/null &
    fi
  done <<< "$pods"

  # Exit when workflow is done
  if [[ "$phase" == "Succeeded" || "$phase" == "Failed" || "$phase" == "Error" ]]; then
    wait 2>/dev/null || true
    echo "" >&2
    echo "=== Workflow $phase ===" >&2
    break
  fi

  sleep 3
done
