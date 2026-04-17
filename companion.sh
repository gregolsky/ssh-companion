#!/bin/bash
# Usage: ./companion.sh ssh [-i key.pem] user@hostname [ssh-options...]
# Opens a tmux session with SSH on the left and Claude on the right.
# Uses an isolated tmux socket with prefix remapped to C-q so C-b passes
# cleanly through to remote tmux (no nested-tmux prefix clash).
# Requires: docker (with 'ssh-companion' container running), tmux, claude CLI.

[[ $# -eq 0 ]] && { echo "Usage: companion.sh ssh [-i key.pem] user@hostname"; exit 1; }

if ! command -v tmux &>/dev/null; then
    if command -v apt-get &>/dev/null;   then INSTALL="sudo apt-get install tmux"
    elif command -v dnf &>/dev/null;     then INSTALL="sudo dnf install tmux"
    elif command -v brew &>/dev/null;    then INSTALL="brew install tmux"
    else                                      INSTALL="<your package manager> install tmux"
    fi
    echo "Error: 'tmux' not found. Install it with: $INSTALL"; exit 1
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

tmux -L "$SOCKET" -f "$TMUX_CONF" new-session -d -s "$SESSION" "docker exec -it ssh-companion $*"
tmux -L "$SOCKET" split-window -h -t "$SESSION" "claude"
tmux -L "$SOCKET" select-pane -t "$SESSION":0.0

if [ -n "$TMUX" ]; then
    tmux -L "$SOCKET" switch-client -t "$SESSION"
else
    tmux -L "$SOCKET" attach -t "$SESSION"
fi
