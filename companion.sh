#!/bin/bash
# Usage: ./companion.sh ssh [-i key.pem] user@hostname [ssh-options...]
# Opens a screen session with SSH on the left and Claude on the right.
# Requires: docker (with 'ssh-companion' container running), screen, claude CLI.

[[ $# -eq 0 ]] && { echo "Usage: companion.sh ssh [-i key.pem] user@hostname"; exit 1; }
command -v screen &>/dev/null || { echo "Error: 'screen' not found. Install it with: sudo apt install screen"; exit 1; }

DEST=""
for arg in "$@"; do
  [[ "$arg" =~ ^- ]] && continue
  DEST="$arg"
done
HOSTNAME="${DEST##*@}"
HOSTNAME="${HOSTNAME%%:*}"
SESSION="companion-${HOSTNAME:-session}"
SESSION="${SESSION//./-}"

claude mcp list 2>/dev/null | grep -q "ssh-companion" || \
  claude mcp add ssh-companion docker -- exec -i ssh-companion python /app/server.py

screen -dmS "$SESSION" bash -c "docker exec -it ssh-companion $*; exec bash"
screen -S "$SESSION" -X split -v
screen -S "$SESSION" -X focus right
screen -S "$SESSION" -X screen bash -c "claude; exec bash"
screen -S "$SESSION" -X focus left

if [ -n "$STY" ]; then
    screen -x "$SESSION"
else
    screen -r "$SESSION"
fi
