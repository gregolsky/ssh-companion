import asyncio
import json
from pathlib import Path

import pytest

import server
from conftest import write_log


# ---------------------------------------------------------------------------
# _hostname_from_path
# ---------------------------------------------------------------------------

def test_hostname_from_path_typical():
    assert server._hostname_from_path(Path("prod-db-1-1713345600.log")) == "prod-db-1"


def test_hostname_from_path_local():
    assert server._hostname_from_path(Path("local-1000000.log")) == "local"


def test_hostname_from_path_ip():
    assert server._hostname_from_path(Path("192-168-1-1-1713345600.log")) == "192-168-1-1"


# ---------------------------------------------------------------------------
# list_sessions
# ---------------------------------------------------------------------------

def test_list_sessions_missing_dir(monkeypatch, tmp_path):
    monkeypatch.setattr(server, "SESSIONS_DIR", tmp_path / "nonexistent")
    assert server.list_sessions() == []


def test_list_sessions_empty_dir(sessions_dir):
    assert server.list_sessions() == []


def test_list_sessions_two_hosts(sessions_dir):
    write_log(sessions_dir, "prod", "hello")
    write_log(sessions_dir, "staging", "world")
    result = server.list_sessions()
    hostnames = [r["hostname"] for r in result]
    assert sorted(hostnames) == ["prod", "staging"]


def test_list_sessions_returns_expected_fields(sessions_dir):
    write_log(sessions_dir, "prod", "hello")
    result = server.list_sessions()
    assert len(result) == 1
    r = result[0]
    assert r["hostname"] == "prod"
    assert r["log_count"] == 1
    assert "last_active" in r
    assert "T" in r["last_active"]  # ISO format
    assert "size_kb" in r


def test_list_sessions_hostname_filter(sessions_dir, monkeypatch):
    write_log(sessions_dir, "prod", "hello")
    write_log(sessions_dir, "staging", "world")
    monkeypatch.setattr(server, "DEFAULT_HOSTNAME", "prod")
    result = server.list_sessions()
    assert len(result) == 1
    assert result[0]["hostname"] == "prod"


# ---------------------------------------------------------------------------
# focus_session
# ---------------------------------------------------------------------------

def test_focus_session_no_logs(sessions_dir):
    result = server.focus_session(hostname="nohost")
    assert "error" in result


def test_focus_session_no_hostname_no_default():
    result = server.focus_session()
    assert result == {"error": "hostname is required"}


def test_focus_session_uses_default_hostname(sessions_dir, monkeypatch):
    write_log(sessions_dir, "prod", "line1\nline2")
    monkeypatch.setattr(server, "DEFAULT_HOSTNAME", "prod")
    result = server.focus_session()
    assert result["hostname"] == "prod"
    assert "line1" in result["content"]


def test_focus_session_strips_ansi(sessions_dir):
    write_log(sessions_dir, "prod", "\x1b[31mred\x1b[0m\nnormal")
    result = server.focus_session(hostname="prod")
    assert "\x1b" not in result["content"]
    assert "red" in result["content"]


def test_focus_session_lines_limit(sessions_dir):
    content = "\n".join(str(i) for i in range(100))
    write_log(sessions_dir, "prod", content)
    result = server.focus_session(hostname="prod", lines=5)
    assert len(result["content"].splitlines()) == 5
    assert result["content"].splitlines()[-1] == "99"


def test_focus_session_byte_offset_equals_file_size(sessions_dir):
    log = write_log(sessions_dir, "prod", "hello\nworld\n")
    result = server.focus_session(hostname="prod")
    assert result["byte_offset"] == log.stat().st_size


# ---------------------------------------------------------------------------
# read_session_since
# ---------------------------------------------------------------------------

def test_read_session_since_no_hostname_no_default():
    result = server.read_session_since(byte_offset=0)
    assert result == {"error": "hostname is required"}


def test_read_session_since_at_end(sessions_dir):
    log = write_log(sessions_dir, "prod", "hello\n")
    size = log.stat().st_size
    result = server.read_session_since(byte_offset=size, hostname="prod")
    assert result["new_content"] == ""
    assert result["lines_added"] == 0


def test_read_session_since_new_content(sessions_dir):
    log = write_log(sessions_dir, "prod", "line1\n")
    offset = log.stat().st_size
    log.open("a").write("line2\nline3\n")
    result = server.read_session_since(byte_offset=offset, hostname="prod")
    assert "line2" in result["new_content"]
    assert "line3" in result["new_content"]
    assert "line1" not in result["new_content"]
    assert result["lines_added"] == 2


def test_read_session_since_rotation(sessions_dir):
    log = write_log(sessions_dir, "prod", "old content\n")
    huge_offset = log.stat().st_size + 9999
    result = server.read_session_since(byte_offset=huge_offset, hostname="prod")
    assert result.get("rewound") is True
    assert "old content" in result["content"]


# ---------------------------------------------------------------------------
# search_session
# ---------------------------------------------------------------------------

def test_search_session_no_hostname_no_default():
    result = server.search_session(pattern="anything")
    assert result == {"error": "hostname is required"}


def test_search_session_no_logs(sessions_dir):
    result = server.search_session(pattern="foo", hostname="nohost")
    assert "error" in result


def test_search_session_finds_matches(sessions_dir):
    write_log(sessions_dir, "prod", "error: disk full\ninfo: ok\nerror: oom")
    result = server.search_session(pattern="error", hostname="prod")
    assert result["truncated"] is False
    assert len(result["matches"]) == 2
    texts = [m["text"] for m in result["matches"]]
    assert any("disk full" in t for t in texts)
    assert any("oom" in t for t in texts)


def test_search_session_match_fields(sessions_dir):
    write_log(sessions_dir, "prod", "hello world")
    result = server.search_session(pattern="hello", hostname="prod")
    m = result["matches"][0]
    assert "logfile" in m
    assert "line_no" in m
    assert "text" in m


def test_search_session_invalid_regex(sessions_dir):
    write_log(sessions_dir, "prod", "some content")
    result = server.search_session(pattern="[invalid", hostname="prod")
    assert "error" in result
    assert "Invalid regex" in result["error"]


def test_search_session_max_matches_truncates(sessions_dir):
    content = "\n".join("match" for _ in range(20))
    write_log(sessions_dir, "prod", content)
    result = server.search_session(pattern="match", hostname="prod", max_matches=5)
    assert len(result["matches"]) == 5
    assert result["truncated"] is True


def test_search_session_case_insensitive(sessions_dir):
    write_log(sessions_dir, "prod", "ERROR: Something bad")
    result = server.search_session(pattern="error", hostname="prod")
    assert len(result["matches"]) == 1


# ---------------------------------------------------------------------------
# Hostname validation and --hostname scoping
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("bad", ["../secret/x", "*", "prod/../x", ".hidden", "a b", "pr?d"])
def test_invalid_hostnames_rejected(sessions_dir, bad):
    write_log(sessions_dir, "prod", "hello")
    for result in (
        server.focus_session(hostname=bad),
        server.read_session_since(byte_offset=0, hostname=bad),
        server.search_session(pattern="hello", hostname=bad),
    ):
        assert "Invalid hostname" in result["error"]


def test_path_traversal_does_not_escape_sessions_dir(tmp_path, monkeypatch):
    sessions = tmp_path / "sessions"
    sessions.mkdir()
    (tmp_path / "secret").mkdir()
    (tmp_path / "secret" / "x-1.log").write_text("top secret")
    monkeypatch.setattr(server, "SESSIONS_DIR", sessions)
    result = server.focus_session(hostname="../secret/x")
    assert "error" in result
    assert "top secret" not in str(result)


def test_other_hostname_rejected_when_restricted(sessions_dir, monkeypatch):
    write_log(sessions_dir, "prod", "hello")
    write_log(sessions_dir, "staging", "secret")
    monkeypatch.setattr(server, "DEFAULT_HOSTNAME", "prod")
    for result in (
        server.focus_session(hostname="staging"),
        server.read_session_since(byte_offset=0, hostname="staging"),
        server.search_session(pattern="secret", hostname="staging"),
    ):
        assert "restricted" in result["error"]
    assert server.focus_session(hostname="prod")["hostname"] == "prod"


def test_hostname_prefix_does_not_match_other_host(sessions_dir):
    write_log(sessions_dir, "prod", "prod output", timestamp=1000)
    write_log(sessions_dir, "prod-db-1", "db output", timestamp=2000)
    result = server.focus_session(hostname="prod")
    assert result["logfile"] == "prod-1000.log"
    found = server.search_session(pattern="output", hostname="prod")
    assert [m["logfile"] for m in found["matches"]] == ["prod-1000.log"]


def test_latest_log_sorted_by_timestamp_not_name(sessions_dir):
    write_log(sessions_dir, "prod", "older", timestamp=999)
    write_log(sessions_dir, "prod", "newer", timestamp=1000)
    assert "newer" in server.focus_session(hostname="prod")["content"]


# ---------------------------------------------------------------------------
# Bounds
# ---------------------------------------------------------------------------

def test_focus_session_lines_clamped(sessions_dir):
    write_log(sessions_dir, "prod", "\n".join(str(i) for i in range(5000)))
    assert len(server.focus_session(hostname="prod", lines=0)["content"].splitlines()) == 1
    assert len(server.focus_session(hostname="prod", lines=-5)["content"].splitlines()) == 1
    big = server.focus_session(hostname="prod", lines=10**9)
    assert len(big["content"].splitlines()) == server.MAX_LINES


def test_focus_session_reads_only_tail_window(sessions_dir, monkeypatch):
    monkeypatch.setattr(server, "TAIL_BYTES", 64)
    log = write_log(sessions_dir, "prod", "\n".join(f"line{i:04d}" for i in range(1000)))
    result = server.focus_session(hostname="prod")
    assert result["content"].splitlines()[-1] == "line0999"
    assert result["total_lines"] < 10
    assert result["byte_offset"] == log.stat().st_size


def test_read_session_since_negative_offset(sessions_dir):
    write_log(sessions_dir, "prod", "hello\n")
    result = server.read_session_since(byte_offset=-1, hostname="prod")
    assert "error" in result


def test_search_session_pattern_too_long(sessions_dir):
    write_log(sessions_dir, "prod", "hello")
    result = server.search_session(pattern="a" * (server.MAX_PATTERN_LEN + 1), hostname="prod")
    assert "too long" in result["error"]


def test_search_session_max_matches_clamped(sessions_dir):
    write_log(sessions_dir, "prod", "\n".join("match" for _ in range(20)))
    result = server.search_session(pattern="match", hostname="prod", max_matches=0)
    assert len(result["matches"]) == 1


def test_valid_dotted_and_ip_hostnames_accepted(sessions_dir):
    write_log(sessions_dir, "192.168.1.1", "ip host")
    write_log(sessions_dir, "web_01.example.com", "dotted host")
    assert "ip host" in server.focus_session(hostname="192.168.1.1")["content"]
    assert "dotted host" in server.focus_session(hostname="web_01.example.com")["content"]


def test_read_session_since_reads_only_tail_window(sessions_dir, monkeypatch):
    monkeypatch.setattr(server, "TAIL_BYTES", 64)
    log = write_log(sessions_dir, "prod", "start\n")
    log.open("a").write("".join(f"line{i:04d}\n" for i in range(1000)))
    result = server.read_session_since(byte_offset=0, hostname="prod")
    assert "start" not in result["new_content"]
    assert result["new_content"].splitlines()[-1] == "line0999"
    assert result["byte_offset"] == log.stat().st_size


def test_search_session_handles_crlf_lines(sessions_dir):
    (sessions_dir / "prod-1.log").write_bytes(b"first\r\nerror here\r\nlast\r\n")
    result = server.search_session(pattern="error", hostname="prod")
    assert result["matches"] == [{"logfile": "prod-1.log", "line_no": 2, "text": "error here"}]


# ---------------------------------------------------------------------------
# Audit log
# ---------------------------------------------------------------------------

def read_audit(sessions_dir):
    path = sessions_dir / "audit.jsonl"
    return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []


def test_each_tool_call_appends_one_audit_record(sessions_dir):
    write_log(sessions_dir, "prod", "error: boom\n")
    server.list_sessions()
    server.focus_session(hostname="prod", lines=5)
    server.read_session_since(byte_offset=0, hostname="prod")
    server.search_session(pattern="error", hostname="prod")
    records = read_audit(sessions_dir)
    assert [r["tool"] for r in records] == ["list_sessions", "focus_session", "read_session_since", "search_session"]
    assert all(r["event"] == "mcp_tool" and r["ok"] for r in records)
    assert records[0]["sessions"] == 1
    assert records[1]["args"] == {"hostname": "prod", "lines": 5}
    assert records[1]["logfile"] == "prod-1000000.log"
    assert records[3]["args"]["pattern"] == "error"
    assert records[3]["matches"] == 1
    assert "T" in records[0]["ts"]


def test_audit_never_contains_session_content(sessions_dir):
    write_log(sessions_dir, "prod", "password=hunter2\n")
    server.focus_session(hostname="prod")
    server.read_session_since(byte_offset=0, hostname="prod")
    assert "hunter2" not in (sessions_dir / "audit.jsonl").read_text()


def test_refused_calls_are_audited(sessions_dir, monkeypatch):
    monkeypatch.setattr(server, "DEFAULT_HOSTNAME", "prod")
    server.focus_session(hostname="staging")
    (record,) = read_audit(sessions_dir)
    assert record["ok"] is False
    assert record["server_hostname"] == "prod"
    assert record["args"] == {"hostname": "staging"}
    assert "restricted" in record["error"]


def test_rewind_is_audited_once(sessions_dir):
    write_log(sessions_dir, "prod", "x\n")
    result = server.read_session_since(byte_offset=10**6, hostname="prod")
    assert result["rewound"] is True
    (record,) = read_audit(sessions_dir)
    assert record["tool"] == "read_session_since" and record["rewound"] is True


def test_audit_file_is_private(sessions_dir):
    server.list_sessions()
    assert (sessions_dir / "audit.jsonl").stat().st_mode & 0o777 == 0o600


def test_unwritable_audit_log_does_not_break_tools(sessions_dir, capsys):
    (sessions_dir / "audit.jsonl").mkdir()  # makes the append fail
    write_log(sessions_dir, "prod", "hello")
    assert "hello" in server.focus_session(hostname="prod")["content"]
    assert "could not write audit log" in capsys.readouterr().err


def test_audit_and_timing_files_are_not_sessions(sessions_dir):
    log = write_log(sessions_dir, "prod", "hello")
    (sessions_dir / f"{log.name}.timing").write_text("0.1 5\n")
    (sessions_dir / "audit.jsonl").write_text("{}\n")
    assert [r["hostname"] for r in server.list_sessions()] == ["prod"]
    assert server.focus_session(hostname="prod")["logfile"] == log.name


def test_tool_schemas_keep_their_parameters():
    tools = {t.name: t for t in asyncio.run(server.mcp.list_tools())}
    assert set(tools) == {"list_sessions", "focus_session", "read_session_since", "search_session"}
    assert set(tools["search_session"].inputSchema["properties"]) == {"pattern", "hostname", "max_matches"}
    assert tools["read_session_since"].inputSchema["required"] == ["byte_offset"]
