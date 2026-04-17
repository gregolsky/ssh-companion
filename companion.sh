#!/bin/bash
# Usage: ./companion.sh [--split|--windows] ssh [-i key.pem] user@hostname [ssh-options...]
# Opens an SSH session alongside Claude, either as a tmux side-by-side split
# (default) or as two separate terminal windows.
# Requires: docker (with 'ssh-companion' container running), claude CLI,
#           plus tmux (for --split) or a supported terminal emulator (for --windows).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_companion-layout.sh"

declare -a REMAINING
parse_layout_args LAYOUT LAYOUT_EXPLICIT REMAINING "$@"
set -- "${REMAINING[@]}"

[[ $# -eq 0 ]] && { echo "Usage: companion.sh [--split|--windows] ssh [-i key.pem] user@hostname"; exit 1; }

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

LEFT_CMD="docker exec -it ssh-companion $*"
RIGHT_CMD="claude"

run_layout "$SESSION" "SSH: ${HOSTNAME:-session}" "$LEFT_CMD" "Claude" "$RIGHT_CMD"
