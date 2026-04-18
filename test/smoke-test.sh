#!/bin/bash
# Copyright 2026 Grzegorz Lachowski
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# End-to-end smoke test: drives start-mcp-server.sh with a temp sessions
# directory, then asserts the container is running, hardened, and functional.
# Usable locally and from CI.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="ssh-companion"
SESSIONS_DIR="$(mktemp -d)"
# Use a throwaway SSH dir so the test never touches the developer's real keys.
SSH_DIR="$(mktemp -d)"

trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$SESSIONS_DIR" "$SSH_DIR"' EXIT

pass=0
fail=0
assert() {
    local desc="$1"; shift
    if "$@"; then
        echo "  PASS  $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL  $desc"
        fail=$((fail + 1))
    fi
}

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

echo "==> Starting container via start-mcp-server.sh"
SSH_COMPANION_SESSIONS="$SESSIONS_DIR" \
SSH_COMPANION_SSH_DIR="$SSH_DIR" \
    bash "$REPO_ROOT/start-mcp-server.sh"

# Give the container a beat to settle before we inspect it.
sleep 1

echo "==> Asserting state"

assert "container is running" \
    bash -c '[ "$(docker inspect -f "{{.State.Running}}" '"$CONTAINER"')" = "true" ]'

assert "--cap-drop=ALL applied" \
    bash -c '[ "$(docker inspect -f "{{.HostConfig.CapDrop}}" '"$CONTAINER"')" = "[ALL]" ]'

assert "no-new-privileges applied" \
    bash -c 'docker inspect -f "{{.HostConfig.SecurityOpt}}" '"$CONTAINER"' | grep -q no-new-privileges'

assert "runs as companion user" \
    bash -c '[ "$(docker exec '"$CONTAINER"' whoami)" = "companion" ]'

assert "runs as non-root uid" \
    bash -c '[ "$(docker exec '"$CONTAINER"' id -u)" != "0" ]'

assert "ssh wrapper in place" \
    docker exec "$CONTAINER" grep -q '/sessions/' /usr/local/bin/ssh

assert "/sessions writable by runtime user" \
    docker exec "$CONTAINER" sh -c 'touch /sessions/.probe && rm /sessions/.probe'

assert "MCP server imports cleanly" \
    bash -c '[ "$(docker exec '"$CONTAINER"' python -c "import sys; sys.path.insert(0, \"/app\"); import server; print(server.mcp.name)")" = "ssh-companion" ]'

echo
echo "==> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
