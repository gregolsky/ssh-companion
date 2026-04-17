#!/bin/bash
# Usage: ./companion.sh ssh [-i key.pem] user@hostname [ssh-options...]
# Opens a screen session with SSH on the left and Claude on the right.
# Requires: docker (with 'ssh-companion' container running), screen, claude CLI.

[[ $# -eq 0 ]] && { echo "Usage: companion.sh ssh [-i key.pem] user@hostname"; exit 1; }
if ! command -v screen &>/dev/null; then
    if command -v apt-get &>/dev/null;   then INSTALL="sudo apt-get install screen"
    elif command -v dnf &>/dev/null;     then INSTALL="sudo dnf install screen"
    elif command -v brew &>/dev/null;    then INSTALL="brew install screen"
    else                                      INSTALL="<your package manager> install screen"
    fi
    echo "Error: 'screen' not found. Install it with: $INSTALL"; exit 1
fi

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
