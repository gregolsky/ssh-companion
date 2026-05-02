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

# Usage: ./companion.sh [--split|--windows] [--no-watch] [--instructions-loop "<prompt>"] ssh [-i key.pem] user@hostname [ssh-options...]
# Opens an SSH session alongside Claude, either as a tmux side-by-side split
# (default) or as two separate terminal windows.
# By default Claude starts a /loop that watches the session every ~60s and
# advises on what is happening. Pass --no-watch to open Claude without the loop,
# or --instructions-loop "<prompt>" to override the default watcher with a
# custom prompt.
# Requires: docker (with 'ssh-companion' container running), claude CLI,
#           plus tmux (for --split) or a supported terminal emulator (for --windows).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_FILE="$SCRIPT_DIR/.mcp.json"
source "$SCRIPT_DIR/_companion-layout.sh"
source "$SCRIPT_DIR/_mcp-entry.sh"

INSTRUCTIONS_LOOP=""
WATCH=1
declare -a PRE_LAYOUT_ARGS
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instructions-loop)
            [[ $# -ge 2 ]] || { echo "Error: --instructions-loop requires a value." >&2; exit 1; }
            INSTRUCTIONS_LOOP="$2"; shift 2 ;;
        --instructions-loop=*)
            INSTRUCTIONS_LOOP="${1#--instructions-loop=}"; shift ;;
        --no-watch)
            WATCH=0; shift ;;
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

if [[ "$(docker inspect -f '{{.State.Running}}' ssh-companion 2>/dev/null)" != "true" ]]; then
    echo "Starting ssh-companion container..."
    "$SCRIPT_DIR/start-mcp-server.sh"
fi

mcp_prune_stale "$MCP_FILE"
MCP_SUFFIX=$(mcp_compute_suffix "$HOSTNAME")
MCP_NAME="ssh-companion-$MCP_SUFFIX"
mcp_add "$MCP_FILE" "$MCP_NAME" "$HOSTNAME"

LEFT_CMD="docker exec -it ssh-companion $*"
if [[ "$LAYOUT" == "split" ]]; then
    LEFT_CMD="docker exec -it ssh-companion $*; RC=\$?; [ \$RC -ne 0 ] && tmux -L ssh-companion kill-session -t $SESSION 2>/dev/null; exit \$RC"
fi
if [[ -z "$INSTRUCTIONS_LOOP" && "$WATCH" -eq 1 ]]; then
    INSTRUCTIONS_LOOP="$(cat "$SCRIPT_DIR/prompts/watch.md")"
fi
if [[ -n "$INSTRUCTIONS_LOOP" ]]; then
    RIGHT_CMD="cd $(printf '%q' "$SCRIPT_DIR") && claude $(printf '%q' "/loop $INSTRUCTIONS_LOOP")"
else
    RIGHT_CMD="cd $(printf '%q' "$SCRIPT_DIR") && claude"
fi

run_layout "$SESSION" "SSH: ${HOSTNAME:-session}" "$LEFT_CMD" "Claude" "$RIGHT_CMD"

# In split mode run_layout blocks (tmux attach) — clean up after it returns.
# In windows mode it returns immediately; stale entries are pruned on the next launch.
if [[ "$LAYOUT" == "split" ]]; then
    mcp_remove "$MCP_FILE" "$MCP_NAME"
fi
