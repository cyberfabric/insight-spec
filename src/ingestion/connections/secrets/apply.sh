#!/usr/bin/env bash
# Apply all connector Secrets to the cluster.
# Usage: ./apply.sh [namespace]
#
# 1. Copy *.yaml.example → *.yaml
# 2. Fill in real credentials
# 3. Run this script
set -euo pipefail

NAMESPACE="${1:-data}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

shopt -s nullglob
files=("$DIR"/*.yaml)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No .yaml files found in $DIR"
  echo "Copy .yaml.example files and fill in credentials:"
  for ex in "$DIR"/*.yaml.example; do
    base="$(basename "$ex" .yaml.example).yaml"
    echo "  cp $ex $DIR/$base"
  done
  exit 1
fi

for f in "${files[@]}"; do
  echo "Applying $(basename "$f") → namespace $NAMESPACE"
  kubectl apply -f "$f" -n "$NAMESPACE"
done

echo "Done. Secrets applied to namespace $NAMESPACE."
