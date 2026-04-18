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

# Shared layout helpers for companion.sh / companion-local.sh.
# Source this file; set $LEFT_CMD, $LEFT_TITLE, $RIGHT_TITLE, $SESSION_NAME,
# then call parse_layout_args "$@" and eval its output to get remaining args,
# then call run_layout.

TERMINAL_CANDIDATES=(
    x-terminal-emulator
    gnome-terminal
    konsole
    alacritty
    kitty
    wezterm
    xfce4-terminal
    xterm
)

detect_terminal() {
    for t in "${TERMINAL_CANDIDATES[@]}"; do
        command -v "$t" &>/dev/null && { echo "$t"; return 0; }
    done
    return 1
}

install_hint() {
    local pkg="$1"
    if command -v apt-get &>/dev/null;   then echo "sudo apt-get install $pkg"
    elif command -v dnf &>/dev/null;     then echo "sudo dnf install $pkg"
    elif command -v brew &>/dev/null;    then echo "brew install $pkg"
    else                                      echo "<your package manager> install $pkg"
    fi
}

# Consume --layout=X / --split / --windows from args.
# Usage: parse_layout_args LAYOUT_VAR EXPLICIT_VAR REST_ARRAY_VAR "$@"
# Requires bash >= 4.3 (namerefs).
parse_layout_args() {
    local -n _layout=$1
    local -n _explicit=$2
    local -n _rest=$3
    shift 3
    _layout="${COMPANION_LAYOUT:-split}"
    _explicit=""
    [[ -n "$COMPANION_LAYOUT" ]] && _explicit=1
    _rest=()
    for arg in "$@"; do
        case "$arg" in
            --layout=*) _layout="${arg#--layout=}"; _explicit=1 ;;
            --split)    _layout=split;   _explicit=1 ;;
            --windows)  _layout=windows; _explicit=1 ;;
            *)          _rest+=("$arg") ;;
        esac
    done
    if [[ "$_layout" != "split" && "$_layout" != "windows" ]]; then
        echo "Error: invalid layout '$_layout' (expected: split | windows)" >&2
        exit 1
    fi
}

launch_term() {
    local title="$1" cmd="$2"
    local term="${COMPANION_TERMINAL_APP:-$(detect_terminal)}" || true
    if [[ -z "$term" ]] || ! command -v "$term" &>/dev/null; then
        echo "Error: no supported terminal emulator found." >&2
        echo "Tried: ${TERMINAL_CANDIDATES[*]}" >&2
        echo "Set COMPANION_TERMINAL_APP=<your-terminal> to override." >&2
        exit 1
    fi
    case "$term" in
        gnome-terminal)  gnome-terminal --title "$title" -- bash -c "$cmd; exec bash" & ;;
        konsole)         konsole -p "tabtitle=$title" -e bash -c "$cmd; exec bash" & ;;
        alacritty)       alacritty -T "$title" -e bash -c "$cmd; exec bash" & ;;
        kitty)           kitty --title "$title" bash -c "$cmd; exec bash" & ;;
        wezterm)         wezterm start -- bash -c "$cmd; exec bash" & ;;
        xfce4-terminal)  xfce4-terminal --title "$title" -e "bash -c '$cmd; exec bash'" & ;;
        xterm|x-terminal-emulator)
                         "$term" -T "$title" -e bash -c "$cmd; exec bash" & ;;
        *)               echo "Error: COMPANION_TERMINAL_APP='$term' not supported." >&2; exit 1 ;;
    esac
    disown 2>/dev/null || true
}

run_split_tmux() {
    local session="$1" left_cmd="$2" right_cmd="$3"
    local socket="ssh-companion"
    local conf
    conf=$(mktemp --suffix=.tmux.conf)
    trap 'rm -f "$conf"' EXIT
    cat > "$conf" <<'EOF'
unbind C-b
set -g prefix C-q
bind C-q send-prefix
set -g mouse on
EOF

    tmux -L "$socket" -f "$conf" new-session -d -s "$session" "$left_cmd"
    tmux -L "$socket" split-window -h -t "$session" "$right_cmd"
    tmux -L "$socket" select-pane -t "$session":0.0

    if [[ -n "$TMUX" ]]; then
        tmux -L "$socket" switch-client -t "$session"
    else
        tmux -L "$socket" attach -t "$session"
    fi
}

run_layout() {
    local session="$1" left_title="$2" left_cmd="$3" right_title="$4" right_cmd="$5"

    if [[ "$LAYOUT" == "split" ]]; then
        if ! command -v tmux &>/dev/null; then
            if [[ -n "$LAYOUT_EXPLICIT" ]]; then
                echo "Error: tmux required for --split layout." >&2
                echo "Install it ($(install_hint tmux)) or use --windows." >&2
                exit 1
            fi
            echo "Note: tmux not found — falling back to --windows layout."
            echo "      Install tmux ($(install_hint tmux)) for a side-by-side split."
            LAYOUT=windows
        fi
    fi

    case "$LAYOUT" in
        split)   run_split_tmux "$session" "$left_cmd" "$right_cmd" ;;
        windows) launch_term "$left_title" "$left_cmd"
                 launch_term "$right_title" "$right_cmd" ;;
    esac
}
