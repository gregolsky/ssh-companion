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
