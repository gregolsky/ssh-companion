#!/bin/bash
set -euo pipefail

IMAGE="${IMAGE:-ssh-companion}"
TAG="${TAG:-latest}"

echo "Building $IMAGE:$TAG..."
docker build -t "$IMAGE:$TAG" .
echo "Done: $IMAGE:$TAG"
