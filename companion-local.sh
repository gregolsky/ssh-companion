#!/bin/bash
# Opens a screen session with a captured local shell on the left and Claude on the right.
# Requires: screen, claude CLI, script (util-linux).

command -v screen &>/dev/null || { echo "Error: 'screen' not found. Install it with: sudo apt install screen"; exit 1; }

SESSIONS_DIR="${SSH_COMPANION_SESSIONS:-$HOME/.ssh-companion-sessions}"
LOGFILE="$SESSIONS_DIR/local-$(date +%s).log"
SESSION="companion-local"

claude mcp list 2>/dev/null | grep -q "ssh-companion" || \
  claude mcp add ssh-companion docker -- exec -i ssh-companion python /app/server.py

mkdir -p "$SESSIONS_DIR"

screen -dmS "$SESSION" bash -c "script -q -f \"$LOGFILE\"; exec bash"
screen -S "$SESSION" -X split -v
screen -S "$SESSION" -X focus right
screen -S "$SESSION" -X screen bash -c "claude; exec bash"
screen -S "$SESSION" -X focus left

if [ -n "$STY" ]; then
    screen -x "$SESSION"
else
    screen -r "$SESSION"
fi
