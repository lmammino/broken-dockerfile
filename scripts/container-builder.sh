#!/usr/bin/env bash
# Create or remove the isolated BuildKit builder used for OCI exports.
# Usage: scripts/container-builder.sh create|remove
set -euo pipefail
NAME="whiteout-test-builder"

case "${1:-}" in
  create) docker buildx create --name "$NAME" --driver docker-container --bootstrap ;;
  remove) docker buildx rm "$NAME" ;;
  *) echo "usage: $0 create|remove" >&2; exit 2 ;;
esac
