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

# Usage: ./companion-local.sh [--split|--windows] [--instructions-loop "<prompt>"]
# Opens a captured local shell alongside Claude, either as a tmux side-by-side
# split (default) or as two separate terminal windows.
# --instructions-loop pre-seeds Claude with `/loop <prompt>` so the watch
# loop starts on launch instead of being typed by hand.
# Requires: claude CLI, script (util-linux), plus tmux (for --split) or a
#           supported terminal emulator (for --windows).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_companion-layout.sh"

INSTRUCTIONS_LOOP=""
declare -a PRE_LAYOUT_ARGS
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instructions-loop)
            [[ $# -ge 2 ]] || { echo "Error: --instructions-loop requires a value." >&2; exit 1; }
            INSTRUCTIONS_LOOP="$2"; shift 2 ;;
        --instructions-loop=*)
            INSTRUCTIONS_LOOP="${1#--instructions-loop=}"; shift ;;
        *)
            PRE_LAYOUT_ARGS+=("$1"); shift ;;
    esac
done
set -- "${PRE_LAYOUT_ARGS[@]}"

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
if [[ -n "$INSTRUCTIONS_LOOP" ]]; then
    RIGHT_CMD="claude $(printf '%q' "/loop $INSTRUCTIONS_LOOP")"
else
    RIGHT_CMD="claude"
fi

run_layout "$SESSION" "local shell" "$LEFT_CMD" "Claude" "$RIGHT_CMD"
