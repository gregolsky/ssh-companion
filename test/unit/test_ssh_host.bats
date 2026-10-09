#!/usr/bin/env bats
# Unit tests for _ssh-host.sh

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    source "$REPO_ROOT/_ssh-host.sh"
}

expect_host() {
    local expected="$1"; shift
    local got
    got="$(ssh_log_host "$@")"
    if [[ "$got" != "$expected" ]]; then
        echo "args: $* -> got '$got', expected '$expected'" >&2
        return 1
    fi
}

@test "plain host and user@host" {
    expect_host prod-db-1 prod-db-1
    expect_host prod-db-1 ubuntu@prod-db-1
    expect_host 10.0.0.5 root@10.0.0.5
}

@test "remote command after the destination is ignored" {
    expect_host prod user@prod uptime
    expect_host prod prod tail -f /var/log/syslog
    expect_host prod prod "systemctl restart x; rm -rf /tmp/build"
}

@test "options with separate values are skipped" {
    expect_host prod -i /home/companion/.ssh/key.pem ubuntu@prod
    expect_host prod -p 2222 -l admin prod uptime
    expect_host prod -o StrictHostKeyChecking=no -J bastion prod
    expect_host prod -L 8080:localhost:80 -E /tmp/log prod
}

@test "options with attached values and combined flags" {
    expect_host prod -p2222 prod
    expect_host prod -vvp 2222 prod
    expect_host prod -tt -A -i key prod htop
    expect_host prod -oBatchMode=yes prod
}

@test "-- ends options" {
    expect_host prod -v -- prod uptime
}

@test "ssh:// URIs" {
    expect_host prod ssh://prod
    expect_host prod ssh://user@prod:2222
    expect_host 2001-db8--1 ssh://user@[2001:db8::1]:22
}

@test "IPv6 destinations map colons and zone separators to dashes" {
    expect_host 2001-db8--1 user@2001:db8::1
    expect_host fe80--1-eth0 fe80::1%eth0
}

@test "host:port typo keeps the host" {
    expect_host prod user@prod:22
}

@test "unsafe or missing destinations become unknown" {
    expect_host unknown
    expect_host unknown -v
    expect_host unknown -p 22
    expect_host unknown ../../tmp/evil
    expect_host unknown user@.hidden
    expect_host unknown 'host;rm'
    expect_host unknown ''
}

@test "result is always accepted by server.py's hostname rule" {
    for d in prod a@b.c ssh://x@[::1]:2 'we!rd' '$(id)' -- ; do
        h="$(ssh_log_host "$d")"
        [[ "$h" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
    done
}

# ---------------------------------------------------------------------------
# claim_log_file
# ---------------------------------------------------------------------------

@test "claim_log_file: creates an empty private <host>-<ts>.log" {
    path="$(claim_log_file "$BATS_TEST_TMPDIR" prod)"
    [[ "$path" =~ ^"$BATS_TEST_TMPDIR"/prod-[0-9]+\.log$ ]]
    [[ -f "$path" && ! -s "$path" ]]
    [[ "$(stat -c %a "$path")" == 600 ]]
}

@test "claim_log_file: a taken second bumps the timestamp instead of overwriting" {
    date() { echo 1000; }  # freeze the clock
    echo "first session" > "$BATS_TEST_TMPDIR/prod-1000.log"
    path="$(claim_log_file "$BATS_TEST_TMPDIR" prod)"
    [[ "$path" == "$BATS_TEST_TMPDIR/prod-1001.log" ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/prod-1000.log")" == "first session" ]]
}

@test "claim_log_file: 10 parallel claims in the same second get distinct files" {
    date() { echo 2000; }
    for i in $(seq 1 10); do
        claim_log_file "$BATS_TEST_TMPDIR" prod > "$BATS_TEST_TMPDIR/claim-$i" &
    done
    wait
    [[ "$(cat "$BATS_TEST_TMPDIR"/claim-* | sort -u | wc -l)" -eq 10 ]]
    [[ "$(find "$BATS_TEST_TMPDIR" -name 'prod-*.log' | wc -l)" -eq 10 ]]
}

@test "claim_log_file: fails on a missing directory" {
    run claim_log_file "$BATS_TEST_TMPDIR/nope" prod
    [[ "$status" -ne 0 ]]
}

# ---------------------------------------------------------------------------
# audit_event
# ---------------------------------------------------------------------------

@test "audit_event: appends one JSON line per event" {
    f="$BATS_TEST_TMPDIR/audit.jsonl"
    audit_event "$f" session_start host prod user alice
    audit_event "$f" session_end host prod exit_code 255
    [[ "$(wc -l < "$f")" -eq 2 ]]
    jq -se '.[0].event == "session_start" and .[0].host == "prod" and .[0].user == "alice"
            and .[1].exit_code == 255 and (.[0].ts | test("^[0-9-]+T[0-9:]+\\+00:00$"))' "$f" >/dev/null
    [[ "$(stat -c %a "$f")" == 600 ]]
}

@test "audit_event: quotes, semicolons and newlines in values stay data" {
    f="$BATS_TEST_TMPDIR/audit.jsonl"
    cmd=$'/usr/bin/ssh prod "a; b" $(id)\nnext'
    audit_event "$f" session_start command "$cmd" 'we"ird' 'k'
    [[ "$(wc -l < "$f")" -eq 1 ]]
    jq -e --arg c "$cmd" '.command == $c and .["we\"ird"] == "k"' "$f" >/dev/null
}

@test "audit_event: unwritable file warns but does not fail" {
    mkdir "$BATS_TEST_TMPDIR/audit.jsonl"
    run audit_event "$BATS_TEST_TMPDIR/audit.jsonl" session_start host prod
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"could not write audit log"* ]]
}
