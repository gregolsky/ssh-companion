#!/bin/bash
# Usage: ./companion-local.sh [--split|--windows]
# Opens a captured local shell alongside Claude, either as a tmux side-by-side
# split (default) or as two separate terminal windows.
# Requires: claude CLI, script (util-linux), plus tmux (for --split) or a
#           supported terminal emulator (for --windows).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_companion-layout.sh"

declare -a REMAINING
parse_layout_args LAYOUT LAYOUT_EXPLICIT REMAINING "$@"
set -- "${REMAINING[@]}"

SESSIONS_DIR="${SSH_COMPANION_SESSIONS:-$HOME/.ssh-companion-sessions}"
LOGFILE="$SESSIONS_DIR/local-$(date +%s).log"
SESSION="companion-local"

claude mcp list 2>/dev/null | grep -q "ssh-companion" || \
  claude mcp add ssh-companion docker -- exec -i ssh-companion python /app/server.py

mkdir -p "$SESSIONS_DIR"

LEFT_CMD="script -q -f \"$LOGFILE\""
RIGHT_CMD="claude"

run_layout "$SESSION" "local shell" "$LEFT_CMD" "Claude" "$RIGHT_CMD"
