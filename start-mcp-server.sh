#!/bin/bash
# Starts the ssh-companion container. Builds the image first if needed.

IMAGE="ssh-companion"
CONTAINER="ssh-companion"
SESSIONS_DIR="${SSH_COMPANION_SESSIONS:-$HOME/.ssh-companion-sessions}"

if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "Building $IMAGE..."
    docker build -t "$IMAGE" "$(dirname "$0")"
fi

if docker container inspect "$CONTAINER" &>/dev/null; then
    echo "$CONTAINER is already running."
    exit 0
fi

mkdir -p "$SESSIONS_DIR"

docker run -d --name "$CONTAINER" \
    -v /tmp:/tmp \
    -v "$SESSIONS_DIR:/sessions" \
    "$IMAGE"

echo "$CONTAINER started. Sessions logged to $SESSIONS_DIR"
