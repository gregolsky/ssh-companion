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

# Sourced by ssh-wrapper (inside the container) and companion.sh (on the host),
# so the session log name and the MCP server's --hostname always agree.

# ssh options that take a value (ssh(1) SYNOPSIS).
SSH_OPTS_WITH_ARG="BbcDEeFIiJLlmOoPpQRSWw"

# ssh_log_host ARGS...  ->  echoes the destination host from ssh's arguments
# (without the leading "ssh"), or "unknown" if it can't be determined or isn't
# safe to use in a file name. Everything after the destination is the remote
# command and is ignored.
ssh_log_host() {
    local dest="" arg opts i
    while [[ $# -gt 0 ]]; do
        arg="$1"; shift
        if [[ "$arg" == "--" ]]; then
            dest="${1:-}"
            break
        fi
        if [[ "$arg" == -?* ]]; then
            opts="${arg#-}"
            for (( i = 0; i < ${#opts}; i++ )); do
                if [[ "$SSH_OPTS_WITH_ARG" == *"${opts:i:1}"* ]]; then
                    # The value is the rest of this word (-p22), else the next argument.
                    (( i + 1 < ${#opts} )) || shift
                    break
                fi
            done
            continue
        fi
        dest="$arg"
        break
    done

    local host="$dest"
    if [[ "$host" == ssh://* ]]; then
        # ssh://[user@]host[:port] or ssh://[user@][v6addr][:port]
        host="${host#ssh://}"
        host="${host%%/*}"
        host="${host##*@}"
        if [[ "$host" == \[*\]* ]]; then
            host="${host#\[}"
            host="${host%%\]*}"
        else
            host="${host%%:*}"
        fi
    else
        host="${host##*@}"
        host="${host#\[}"
        host="${host%\]}"
        # One colon is a host:port typo; two or more is an IPv6 address.
        [[ "$host" == *:*:* ]] || host="${host%%:*}"
    fi
    host="${host//[:%]/-}"

    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || host="unknown"
    echo "$host"
}

# claim_log_file DIR HOST  ->  creates and echoes a new, empty, private log file
# DIR/HOST-<ts>.log. If that second is already taken by another session the
# timestamp is bumped instead of overwriting it, which keeps the
# <host>-<digits>.log format server.py parses (the exact start time is in the
# script header anyway).
claim_log_file() {
    local dir="$1" host="$2" ts path tries
    ts="$(date +%s)"
    for (( tries = 0; tries < 1000; tries++ )); do
        path="${dir}/${host}-$(( ts + tries )).log"
        if ( umask 077; set -o noclobber; : > "$path" ) 2>/dev/null; then
            echo "$path"
            return 0
        fi
        [[ -d "$dir" && -w "$dir" ]] || return 1
    done
    return 1
}

# audit_event FILE EVENT [KEY VALUE]...  —  appends one JSON line
# {"ts":…,"event":EVENT,KEY:VALUE,…} to FILE. Values are passed to jq as data,
# never as filter text. Never fails the caller: a session must not be blocked
# because the audit log is unwritable.
audit_event() {
    local file="$1" event="$2" line
    shift 2
    line="$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" --arg event "$event" '
        $ARGS.positional as $kv
        | reduce range(0; $kv | length; 2) as $i ({ts: $ts, event: $event};
            .[$kv[$i]] = (if $kv[$i] == "exit_code" then ($kv[$i + 1] | tonumber? // $kv[$i + 1]) else $kv[$i + 1] end))
    ' --args "$@")" || { echo "ssh-companion: could not build audit record" >&2; return 0; }
    ( umask 077; printf '%s\n' "$line" >> "$file" ) 2>/dev/null \
        || echo "ssh-companion: could not write audit log $file" >&2
    return 0
}
