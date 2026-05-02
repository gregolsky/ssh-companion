#!/usr/bin/env bats
# Unit tests for _mcp-entry.sh

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    MCP_FILE="$(mktemp)"
    rm -f "$MCP_FILE"  # let helpers create it
    export MCP_FILE
    source "$REPO_ROOT/_mcp-entry.sh"
}

teardown() {
    rm -f "$MCP_FILE" "$MCP_FILE.lock"
}

# ---------------------------------------------------------------------------
# mcp_compute_suffix
# ---------------------------------------------------------------------------

@test "mcp_compute_suffix: sanitizes dots in hostname" {
    result="$(mcp_compute_suffix "host.example.com")"
    [[ "$result" == host-example-com-* ]]
}

@test "mcp_compute_suffix: sanitizes colons in hostname" {
    result="$(mcp_compute_suffix "1.2.3.4:22")"
    [[ "$result" == 1-2-3-4-22-* ]]
}

@test "mcp_compute_suffix: empty hostname falls back to session-<pid>" {
    result="$(mcp_compute_suffix "")"
    [[ "$result" == session-* ]]
}

@test "mcp_compute_suffix: plain hostname passes through with pid suffix" {
    result="$(mcp_compute_suffix "myhost")"
    [[ "$result" == myhost-* ]]
}

# ---------------------------------------------------------------------------
# mcp_add
# ---------------------------------------------------------------------------

@test "mcp_add: creates file from example template when missing" {
    cp "$REPO_ROOT/.mcp.json.example" "$REPO_ROOT/.mcp.json.example.bak" 2>/dev/null || true
    mcp_add "$MCP_FILE" "ssh-companion-test-1" "myhost"
    [[ -f "$MCP_FILE" ]]
    jq -e '.mcpServers["ssh-companion-test-1"]' "$MCP_FILE" >/dev/null
}

@test "mcp_add: falls back to empty mcpServers when no template or file" {
    rm -f "$MCP_FILE"
    local ex="$REPO_ROOT/.mcp.json.example"
    local ex_bak
    ex_bak="$(mktemp)"
    [[ -f "$ex" ]] && { cp "$ex" "$ex_bak"; rm "$ex"; } || rm -f "$ex_bak"
    mcp_add "$MCP_FILE" "ssh-companion-test-1" "myhost"
    [[ -f "$ex_bak" ]] && mv "$ex_bak" "$ex" || true
    [[ -f "$MCP_FILE" ]]
    jq -e '.mcpServers["ssh-companion-test-1"]' "$MCP_FILE" >/dev/null
}

@test "mcp_add: entry has correct command and --hostname arg" {
    mcp_add "$MCP_FILE" "ssh-companion-prod-1" "prod"
    local cmd
    cmd="$(jq -r '.mcpServers["ssh-companion-prod-1"].command' "$MCP_FILE")"
    [[ "$cmd" == "docker" ]]
    local last_two_args
    last_two_args="$(jq -r '.mcpServers["ssh-companion-prod-1"].args[-2:]|join(" ")' "$MCP_FILE")"
    [[ "$last_two_args" == "--hostname prod" ]]
}

@test "mcp_add: second add preserves first entry" {
    mcp_add "$MCP_FILE" "ssh-companion-a-1" "a"
    mcp_add "$MCP_FILE" "ssh-companion-b-2" "b"
    local count
    count="$(jq '.mcpServers | length' "$MCP_FILE")"
    [[ "$count" -eq 2 ]]
}

@test "mcp_add: re-adding same name overwrites without duplicating" {
    mcp_add "$MCP_FILE" "ssh-companion-a-1" "a"
    mcp_add "$MCP_FILE" "ssh-companion-a-1" "b"
    local count
    count="$(jq '.mcpServers | length' "$MCP_FILE")"
    [[ "$count" -eq 1 ]]
    # hostname should now be b
    local h
    h="$(jq -r '.mcpServers["ssh-companion-a-1"].args[-1]' "$MCP_FILE")"
    [[ "$h" == "b" ]]
}

# ---------------------------------------------------------------------------
# mcp_remove
# ---------------------------------------------------------------------------

@test "mcp_remove: removes only the named entry, leaves sibling intact" {
    mcp_add "$MCP_FILE" "ssh-companion-a-1" "a"
    mcp_add "$MCP_FILE" "ssh-companion-b-2" "b"
    mcp_remove "$MCP_FILE" "ssh-companion-a-1"
    jq -e 'if .mcpServers | has("ssh-companion-a-1") then error else . end' "$MCP_FILE" >/dev/null
    jq -e '.mcpServers["ssh-companion-b-2"]' "$MCP_FILE" >/dev/null
}

@test "mcp_remove: idempotent when entry is absent" {
    mcp_add "$MCP_FILE" "ssh-companion-a-1" "a"
    mcp_remove "$MCP_FILE" "ssh-companion-nonexistent"
    local count
    count="$(jq '.mcpServers | length' "$MCP_FILE")"
    [[ "$count" -eq 1 ]]
}

@test "mcp_remove: no-ops gracefully when file is missing" {
    rm -f "$MCP_FILE"
    run mcp_remove "$MCP_FILE" "ssh-companion-a-1"
    [[ "$status" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# mcp_prune_stale
# ---------------------------------------------------------------------------

@test "mcp_prune_stale: no-ops when file is missing" {
    rm -f "$MCP_FILE"
    run mcp_prune_stale "$MCP_FILE"
    [[ "$status" -eq 0 ]]
}

@test "mcp_prune_stale: no-ops with zero stale entries" {
    local live_pid=$$
    mcp_add "$MCP_FILE" "ssh-companion-live-${live_pid}" "live"
    mcp_prune_stale "$MCP_FILE"
    local count
    count="$(jq '.mcpServers | length' "$MCP_FILE")"
    [[ "$count" -eq 1 ]]
}

@test "mcp_prune_stale: removes single stale entry" {
    mcp_add "$MCP_FILE" "ssh-companion-dead-999999999" "dead"
    mcp_prune_stale "$MCP_FILE"
    local count
    count="$(jq '.mcpServers | length' "$MCP_FILE")"
    [[ "$count" -eq 0 ]]
}

@test "mcp_prune_stale: removes multiple stale entries (regression for jq filter bug)" {
    mcp_add "$MCP_FILE" "ssh-companion-dead1-999999991" "dead1"
    mcp_add "$MCP_FILE" "ssh-companion-dead2-999999992" "dead2"
    mcp_add "$MCP_FILE" "ssh-companion-dead3-999999993" "dead3"
    mcp_prune_stale "$MCP_FILE"
    local count
    count="$(jq '.mcpServers | length' "$MCP_FILE")"
    [[ "$count" -eq 0 ]]
}

@test "mcp_prune_stale: keeps live entries, removes stale" {
    local live_pid=$$
    mcp_add "$MCP_FILE" "ssh-companion-live-${live_pid}" "live"
    mcp_add "$MCP_FILE" "ssh-companion-dead-999999999" "dead"
    mcp_prune_stale "$MCP_FILE"
    local count
    count="$(jq '.mcpServers | length' "$MCP_FILE")"
    [[ "$count" -eq 1 ]]
    jq -e ".mcpServers[\"ssh-companion-live-${live_pid}\"]" "$MCP_FILE" >/dev/null
}

@test "mcp_prune_stale: ignores entries not matching naming pattern" {
    echo '{"mcpServers":{"some-other-tool":{"command":"foo","args":[]}}}' > "$MCP_FILE"
    mcp_prune_stale "$MCP_FILE"
    jq -e '.mcpServers["some-other-tool"]' "$MCP_FILE" >/dev/null
}

# ---------------------------------------------------------------------------
# Concurrency
# ---------------------------------------------------------------------------

@test "mcp_add: 10 parallel adds all land without JSON corruption" {
    echo '{"mcpServers":{}}' > "$MCP_FILE"
    local pids=()
    for i in $(seq 1 10); do
        mcp_add "$MCP_FILE" "ssh-companion-host${i}-${i}000" "host${i}" &
        pids+=($!)
    done
    wait "${pids[@]}"
    local count
    count="$(jq '.mcpServers | length' "$MCP_FILE")"
    [[ "$count" -eq 10 ]]
}
