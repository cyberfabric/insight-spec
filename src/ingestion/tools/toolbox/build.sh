#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INGESTION_DIR="$SCRIPT_DIR/../.."
IMAGE_NAME="${TOOLBOX_IMAGE:-insight-toolbox:local}"

echo "Building ${IMAGE_NAME}..."
docker build -t "$IMAGE_NAME" \
  -f "$SCRIPT_DIR/Dockerfile" \
  "$INGESTION_DIR"

# Load into Kind cluster if running locally
if command -v kind &>/dev/null && kind get clusters 2>/dev/null | grep -q "^insight$"; then
  echo "Loading into Kind cluster..."
  kind load docker-image "$IMAGE_NAME" --name insight
fi

echo "Done: ${IMAGE_NAME}"
