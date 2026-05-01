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

# Sourced by companion.sh and companion-local.sh.
# Manages per-session entries in the project-local .mcp.json.

_mcp_flock_cmd() {
    if command -v flock >/dev/null 2>&1; then
        flock "$@"
    else
        python3 -c "
import fcntl, sys, subprocess
with open(sys.argv[1], 'w') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    subprocess.run(sys.argv[2:], check=True)
" "$@"
    fi
}

# mcp_compute_suffix HOSTNAME  ->  echoes "<sanitized-host>-<pid>" or "session-<pid>"
mcp_compute_suffix() {
    local host="$1"
    local sanitized="${host//[.:]/-}"
    if [[ -z "$sanitized" ]]; then
        sanitized="session"
    fi
    echo "${sanitized}-$$"
}

# mcp_add MCP_FILE NAME HOSTNAME
mcp_add() {
    local mcp_file="$1" name="$2" hostname="$3"
    local lockfile="${mcp_file}.lock"
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local template="${script_dir}/.mcp.json.example"

    (
        _mcp_flock_cmd -x 9

        if [[ ! -f "$mcp_file" ]]; then
            if [[ -f "$template" ]]; then
                cp "$template" "$mcp_file"
            else
                echo '{"mcpServers":{}}' > "$mcp_file"
            fi
        fi

        local tmp
        tmp="$(mktemp "${mcp_file}.XXXXXX")"
        jq --arg n "$name" --arg h "$hostname" \
            '.mcpServers[$n] = {command:"docker", args:["exec","-i","ssh-companion","python","/app/server.py","--hostname",$h]}' \
            "$mcp_file" > "$tmp" && mv "$tmp" "$mcp_file"
    ) 9>"$lockfile"
}

# mcp_remove MCP_FILE NAME
mcp_remove() {
    local mcp_file="$1" name="$2"
    local lockfile="${mcp_file}.lock"

    [[ -f "$mcp_file" ]] || return 0

    (
        _mcp_flock_cmd -x 9

        local tmp
        tmp="$(mktemp "${mcp_file}.XXXXXX")"
        jq --arg n "$name" 'del(.mcpServers[$n])' \
            "$mcp_file" > "$tmp" && mv "$tmp" "$mcp_file"
    ) 9>"$lockfile"
}

# mcp_prune_stale MCP_FILE  —  removes entries whose embedded PID is no longer alive
mcp_prune_stale() {
    local mcp_file="$1"
    local lockfile="${mcp_file}.lock"

    [[ -f "$mcp_file" ]] || return 0

    (
        _mcp_flock_cmd -x 9

        local names
        names=$(jq -r '.mcpServers // {} | keys[] | select(test("^ssh-companion-.*-[0-9]+$"))' "$mcp_file" 2>/dev/null)

        local to_del=()
        local name pid
        while IFS= read -r name; do
            pid="${name##*-}"
            if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
                to_del+=("$name")
            fi
        done <<< "$names"

        if [[ ${#to_del[@]} -gt 0 ]]; then
            local tmp filter="."
            for name in "${to_del[@]}"; do
                filter+=" | del(.mcpServers[\"$name\"])"
            done
            tmp="$(mktemp "${mcp_file}.XXXXXX")"
            jq "$filter" "$mcp_file" > "$tmp" && mv "$tmp" "$mcp_file"
        fi
    ) 9>"$lockfile"
}
