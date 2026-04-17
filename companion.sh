#!/bin/bash
# Usage: ./peep.sh ssh [-i key.pem] user@hostname [ssh-options...]
# Opens a tmux session with SSH on the left and Claude on the right.
# Requires: docker (with 'peep' container running), tmux, claude CLI.

[[ $# -eq 0 ]] && { echo "Usage: peep.sh ssh [-i key.pem] user@hostname"; exit 1; }

# Extract destination (last non-flag arg) for the session name
DEST=""
for arg in "$@"; do
  [[ "$arg" =~ ^- ]] && continue
  DEST="$arg"
done
HOSTNAME="${DEST##*@}"
HOSTNAME="${HOSTNAME%%:*}"
SESSION="peep-${HOSTNAME:-session}"

tmux new-session -d -s "$SESSION" 2>/dev/null || true
tmux send-keys -t "$SESSION" "docker exec -it peep $*" Enter
tmux split-window -h -t "$SESSION"
tmux send-keys -t "$SESSION" "claude" Enter
tmux select-pane -t "$SESSION.0"

if [ -n "$TMUX" ]; then
    tmux switch-client -t "$SESSION"
else
    tmux attach -t "$SESSION"
fi
