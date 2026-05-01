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

# Usage: ./companion.sh [--split|--windows] [--instructions-loop "<prompt>"] ssh [-i key.pem] user@hostname [ssh-options...]
# Opens an SSH session alongside Claude, either as a tmux side-by-side split
# (default) or as two separate terminal windows.
# --instructions-loop pre-seeds Claude with `/loop <prompt>` so the watch
# loop starts on launch instead of being typed by hand.
# Requires: docker (with 'ssh-companion' container running), claude CLI,
#           plus tmux (for --split) or a supported terminal emulator (for --windows).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_FILE="$SCRIPT_DIR/.mcp.json"
source "$SCRIPT_DIR/_companion-layout.sh"
source "$SCRIPT_DIR/_mcp-entry.sh"

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

[[ $# -eq 0 ]] && { echo "Usage: companion.sh [--split|--windows] [--instructions-loop \"<prompt>\"] ssh [-i key.pem] user@hostname"; exit 1; }

DEST=""
for arg in "$@"; do
  [[ "$arg" =~ ^- ]] && continue
  DEST="$arg"
done
HOSTNAME="${DEST##*@}"
HOSTNAME="${HOSTNAME%%:*}"
SESSION="companion-${HOSTNAME:-session}"
SESSION="${SESSION//./-}"

mcp_prune_stale "$MCP_FILE"
MCP_SUFFIX=$(mcp_compute_suffix "$HOSTNAME")
MCP_NAME="ssh-companion-$MCP_SUFFIX"
mcp_add "$MCP_FILE" "$MCP_NAME" "$HOSTNAME"

LEFT_CMD="docker exec -it ssh-companion $*"
if [[ -n "$INSTRUCTIONS_LOOP" ]]; then
    RIGHT_CMD="claude $(printf '%q' "/loop $INSTRUCTIONS_LOOP")"
else
    RIGHT_CMD="claude"
fi

run_layout "$SESSION" "SSH: ${HOSTNAME:-session}" "$LEFT_CMD" "Claude" "$RIGHT_CMD"

# In split mode run_layout blocks (tmux attach) — clean up after it returns.
# In windows mode it returns immediately; stale entries are pruned on the next launch.
if [[ "$LAYOUT" == "split" ]]; then
    mcp_remove "$MCP_FILE" "$MCP_NAME"
fi
