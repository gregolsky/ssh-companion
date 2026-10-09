#!/usr/bin/env bats
# Unit tests for _companion-layout.sh

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    unset COMPANION_LAYOUT
    source "$REPO_ROOT/_companion-layout.sh"
    # Stub docker: record each argument on its own line instead of running it.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/docker-args"
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH" BATS_TEST_TMPDIR
}

# ---------------------------------------------------------------------------
# build_ssh_cmd
# ---------------------------------------------------------------------------

@test "build_ssh_cmd: shell metacharacters in args are not executed locally" {
    local marker="$BATS_TEST_TMPDIR/pwned"
    cmd="$(build_ssh_cmd ssh prod "uptime; touch $marker" '$(touch '"$marker"')' "a|b")"
    bash -c "$cmd"
    [[ ! -e "$marker" ]]
}

@test "build_ssh_cmd: each argument reaches docker unchanged" {
    cmd="$(build_ssh_cmd ssh -i "/k/my key" user@prod "echo 'hi there'; ls")"
    bash -c "$cmd"
    mapfile -t got < "$BATS_TEST_TMPDIR/docker-args"
    expected=(exec -it -e "COMPANION_HOST_USER=${USER:-unknown}" ssh-companion ssh -i "/k/my key" user@prod "echo 'hi there'; ls")
    [[ "${#got[@]}" -eq "${#expected[@]}" ]]
    for i in "${!expected[@]}"; do
        [[ "${got[$i]}" == "${expected[$i]}" ]]
    done
}

# ---------------------------------------------------------------------------
# parse_layout_args
# ---------------------------------------------------------------------------

@test "parse_layout_args: defaults to split and passes other args through" {
    parse_layout_args LAYOUT EXPLICIT REST ssh -p 22 host
    [[ "$LAYOUT" == "split" && -z "$EXPLICIT" ]]
    [[ "${REST[*]}" == "ssh -p 22 host" ]]
}

@test "parse_layout_args: --windows and --layout= are consumed and explicit" {
    parse_layout_args LAYOUT EXPLICIT REST --windows ssh host
    [[ "$LAYOUT" == "windows" && "$EXPLICIT" == 1 && "${REST[*]}" == "ssh host" ]]
    parse_layout_args LAYOUT EXPLICIT REST --layout=split ssh host
    [[ "$LAYOUT" == "split" && "$EXPLICIT" == 1 ]]
}

@test "parse_layout_args: COMPANION_LAYOUT env sets the default" {
    COMPANION_LAYOUT=windows parse_layout_args LAYOUT EXPLICIT REST ssh host
    [[ "$LAYOUT" == "windows" && "$EXPLICIT" == 1 ]]
}

@test "parse_layout_args: invalid layout exits with error" {
    run parse_layout_args LAYOUT EXPLICIT REST --layout=bogus
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"invalid layout"* ]]
}
