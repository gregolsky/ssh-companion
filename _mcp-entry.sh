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

# jq filters are passed through _mcp_jq_update; their $vars are jq's, not the shell's.
# shellcheck disable=SC2016

# Sourced by companion.sh and companion-local.sh.
# Manages per-session entries in the project-local .mcp.json and the matching
# allow-rules in .claude/settings.local.json (per-user, never committed).
# All writes to both files happen under one lock on "<mcp_file>.lock" (fd 9).

# Take an exclusive lock on fd 9, held until the calling subshell exits.
_mcp_lock_fd9() {
    if command -v flock >/dev/null 2>&1; then
        flock -x 9
    else
        python3 -c 'import fcntl, sys; fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX)' 9
    fi
}

# mcp_compute_suffix HOSTNAME  ->  echoes "<sanitized-host>-<pid>" or "session-<pid>"
# Only [A-Za-z0-9_-] survive, so the server name matches Claude Code's tool names.
mcp_compute_suffix() {
    local host="$1"
    local sanitized="${host//[^A-Za-z0-9_-]/-}"
    if [[ -z "$sanitized" ]]; then
        sanitized="session"
    fi
    echo "${sanitized}-$$"
}

# _mcp_settings_file MCP_FILE  ->  echoes path to .claude/settings.local.json
_mcp_settings_file() {
    echo "$(dirname "$1")/.claude/settings.local.json"
}

# _mcp_jq_update FILE [JQ-ARGS...] FILTER  —  rewrite FILE through jq; leaves FILE
# untouched and removes the temp file if jq fails.
_mcp_jq_update() {
    local file="$1"; shift
    local tmp
    tmp="$(mktemp "${file}.XXXXXX")" || return 1
    if jq "$@" "$file" > "$tmp"; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

# _mcp_add_permission SETTINGS_FILE NAME  —  caller must hold the lock
_mcp_add_permission() {
    local settings_file="$1" name="$2"
    mkdir -p "$(dirname "$settings_file")"
    [[ -f "$settings_file" ]] || echo '{}' > "$settings_file"
    _mcp_jq_update "$settings_file" --arg p "mcp__${name}" \
        '.permissions.allow = (((.permissions.allow // []) - [$p]) + [$p])'
}

# _mcp_remove_permissions SETTINGS_FILE NAMES  —  NAMES is newline-separated;
# caller must hold the lock
_mcp_remove_permissions() {
    local settings_file="$1" names="$2"
    [[ -f "$settings_file" ]] || return 0
    _mcp_jq_update "$settings_file" --arg names "$names" \
        '.permissions.allow = ((.permissions.allow // []) - [$names | split("\n")[] | "mcp__" + .])'
}

# mcp_add MCP_FILE NAME HOSTNAME
mcp_add() {
    local mcp_file="$1" name="$2" hostname="$3"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local template="${script_dir}/.mcp.json.example"
    local settings_file
    settings_file="$(_mcp_settings_file "$mcp_file")"

    (
        _mcp_lock_fd9

        if [[ ! -f "$mcp_file" ]]; then
            if [[ -f "$template" ]]; then
                cp "$template" "$mcp_file"
            else
                echo '{"mcpServers":{}}' > "$mcp_file"
            fi
        fi

        _mcp_jq_update "$mcp_file" --arg n "$name" --arg h "$hostname" \
            '.mcpServers[$n] = {command:"docker", args:["exec","-i","ssh-companion","python","/app/server.py","--hostname",$h]}' \
            && _mcp_add_permission "$settings_file" "$name"
    ) 9>"${mcp_file}.lock"
}

# mcp_remove MCP_FILE NAME
mcp_remove() {
    local mcp_file="$1" name="$2"
    local settings_file
    settings_file="$(_mcp_settings_file "$mcp_file")"

    [[ -f "$mcp_file" ]] || return 0

    (
        _mcp_lock_fd9
        _mcp_jq_update "$mcp_file" --arg n "$name" 'del(.mcpServers[$n])'
        _mcp_remove_permissions "$settings_file" "$name"
    ) 9>"${mcp_file}.lock"
}

# mcp_prune_stale MCP_FILE  —  removes entries whose embedded PID is no longer alive
mcp_prune_stale() {
    local mcp_file="$1"
    local settings_file
    settings_file="$(_mcp_settings_file "$mcp_file")"

    [[ -f "$mcp_file" ]] || return 0

    (
        _mcp_lock_fd9

        local name stale=""
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            kill -0 "${name##*-}" 2>/dev/null || stale+="${name}"$'\n'
        done < <(jq -r '.mcpServers // {} | keys[] | select(test("^ssh-companion-.*-[0-9]+$"))' "$mcp_file" 2>/dev/null)

        [[ -n "$stale" ]] || exit 0
        stale="${stale%$'\n'}"

        _mcp_jq_update "$mcp_file" --arg names "$stale" \
            'reduce ($names | split("\n"))[] as $n (.; del(.mcpServers[$n]))'
        _mcp_remove_permissions "$settings_file" "$stale"
    ) 9>"${mcp_file}.lock"
}
