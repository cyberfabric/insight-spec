#!/usr/bin/env bash
#
# Install/upgrade the Insight umbrella chart.
#
# Assumes Airbyte and Argo Workflows are already installed (ingestion
# services will not work otherwise). Run AFTER install-airbyte.sh and
# install-argo.sh, or alongside them.
#
# Environment overrides:
#   INSIGHT_NAMESPACE    (default: insight)
#   INSIGHT_RELEASE      (default: insight)
#   INSIGHT_VERSION      (default: auto — read from Chart.yaml)
#   INSIGHT_VALUES       single extra -f values.yaml (back-compat)
#   INSIGHT_VALUES_FILES colon-separated list of -f values files, applied in order
#   CHART_SOURCE         local | oci   (default: local — path to charts/insight)
#   OCI_REF              OCI reference for the chart (default: oci://ghcr.io/cyberfabric/charts/insight)
#
# Usage:
#   ./deploy/scripts/install-insight.sh
#   INSIGHT_VALUES=deploy/prod-values.yaml ./deploy/scripts/install-insight.sh
#   CHART_SOURCE=oci INSIGHT_VERSION=0.2.0 ./deploy/scripts/install-insight.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

NAMESPACE="${INSIGHT_NAMESPACE:-insight}"
RELEASE="${INSIGHT_RELEASE:-insight}"
CHART_SOURCE="${CHART_SOURCE:-local}"
OCI_REF="${OCI_REF:-oci://ghcr.io/cyberfabric/charts/insight}"
EXTRA_VALUES="${INSIGHT_VALUES:-}"
EXTRA_VALUES_FILES="${INSIGHT_VALUES_FILES:-}"

log() { printf '\033[36m[install-insight]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[install-insight] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ─── Resolve chart reference ──────────────────────────────────────────
case "$CHART_SOURCE" in
  local)
    CHART_REF="./charts/insight"
    [[ -f "$CHART_REF/Chart.yaml" ]] || die "local chart not found: $CHART_REF"
    log "Ensuring subchart dependencies"
    helm dependency update "$CHART_REF" >/dev/null
    # Auto-detect version if not set
    VERSION="${INSIGHT_VERSION:-$(grep '^version:' "$CHART_REF/Chart.yaml" | awk '{print $2}')}"
    VERSION_ARG=()
    ;;
  oci)
    [[ -n "${INSIGHT_VERSION:-}" ]] || die "INSIGHT_VERSION required for CHART_SOURCE=oci"
    VERSION="$INSIGHT_VERSION"
    CHART_REF="$OCI_REF"
    VERSION_ARG=(--version "$VERSION")
    ;;
  *)
    die "unknown CHART_SOURCE: $CHART_SOURCE (expected: local | oci)"
    ;;
esac

# ─── Prerequisites ─────────────────────────────────────────────────────
command -v helm    >/dev/null || die "helm not found"
command -v kubectl >/dev/null || die "kubectl not found"

log "Cluster: $(kubectl config current-context)"
log "Namespace: $NAMESPACE · Release: $RELEASE · Chart: $CHART_REF@$VERSION"

# ─── Check Airbyte is reachable (warning only) ─────────────────────────
# Single-namespace model: Airbyte lives in the same namespace as Insight.
if ! kubectl -n "$NAMESPACE" get svc airbyte-airbyte-server-svc >/dev/null 2>&1; then
  log "WARNING: Airbyte not detected in the '$NAMESPACE' namespace."
  log "         Ingestion workflows will fail until Airbyte is installed."
  log "         Run: INSIGHT_NAMESPACE=$NAMESPACE ./deploy/scripts/install-airbyte.sh"
fi

# ─── Install / upgrade ─────────────────────────────────────────────────
VALUES_ARGS=()
if [[ -n "$EXTRA_VALUES_FILES" ]]; then
  # Colon-separated list — apply in order so later files override earlier.
  IFS=':' read -ra _FILES <<< "$EXTRA_VALUES_FILES"
  for _f in "${_FILES[@]}"; do
    [[ -f "$_f" ]] || die "values file not found: $_f"
    VALUES_ARGS+=(-f "$_f")
  done
fi
[[ -n "$EXTRA_VALUES" ]] && VALUES_ARGS+=(-f "$EXTRA_VALUES")

# HELM_EXTRA_ARGS: caller-supplied passthrough (e.g. --set flags). Split
# on whitespace — caller is responsible for not embedding spaces.
EXTRA_ARGS=()
if [[ -n "${HELM_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_ARGS=($HELM_EXTRA_ARGS)
fi

log "Running helm upgrade --install"
helm upgrade --install "$RELEASE" "$CHART_REF" \
  --namespace "$NAMESPACE" --create-namespace \
  "${VERSION_ARG[@]}" \
  "${VALUES_ARGS[@]}" \
  "${EXTRA_ARGS[@]}" \
  --wait --timeout 10m

# ─── Summary ───────────────────────────────────────────────────────────
cat <<EOF

✓ Insight installed.

Verify:
  kubectl -n $NAMESPACE rollout status deploy --timeout=5m

Access:
  kubectl -n $NAMESPACE port-forward svc/$RELEASE-frontend 8080:80
  # then open http://localhost:8080

EOF
