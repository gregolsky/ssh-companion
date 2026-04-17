#!/bin/bash
# Opens a tmux session with a captured local shell on the left and Claude on the right.
# Uses an isolated tmux socket with prefix remapped to C-q so C-b passes
# cleanly through to any remote tmux (no nested-tmux prefix clash).
# Requires: tmux, claude CLI, script (util-linux).

if ! command -v tmux &>/dev/null; then
    if command -v apt-get &>/dev/null;   then INSTALL="sudo apt-get install tmux"
    elif command -v dnf &>/dev/null;     then INSTALL="sudo dnf install tmux"
    elif command -v brew &>/dev/null;    then INSTALL="brew install tmux"
    else                                      INSTALL="<your package manager> install tmux"
    fi
    echo "Error: 'tmux' not found. Install it with: $INSTALL"; exit 1
fi

SESSIONS_DIR="${SSH_COMPANION_SESSIONS:-$HOME/.ssh-companion-sessions}"
LOGFILE="$SESSIONS_DIR/local-$(date +%s).log"
SESSION="companion-local"
SOCKET="ssh-companion"

TMUX_CONF=$(mktemp --suffix=.tmux.conf)
trap 'rm -f "$TMUX_CONF"' EXIT
cat > "$TMUX_CONF" <<'EOF'
unbind C-b
set -g prefix C-q
bind C-q send-prefix
set -g mouse on
EOF

claude mcp list 2>/dev/null | grep -q "ssh-companion" || \
  claude mcp add ssh-companion docker -- exec -i ssh-companion python /app/server.py

mkdir -p "$SESSIONS_DIR"

tmux -L "$SOCKET" -f "$TMUX_CONF" new-session -d -s "$SESSION" "script -q -f \"$LOGFILE\""
tmux -L "$SOCKET" split-window -h -t "$SESSION" "claude"
tmux -L "$SOCKET" select-pane -t "$SESSION":0.0

if [ -n "$TMUX" ]; then
    tmux -L "$SOCKET" switch-client -t "$SESSION"
else
    tmux -L "$SOCKET" attach -t "$SESSION"
fi
