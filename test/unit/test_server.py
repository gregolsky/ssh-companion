import asyncio
import json
import os
import time
from pathlib import Path

import pytest

import server
import transcript
from conftest import write_log

FIXTURES = Path(__file__).parent / "fixtures"


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
    assert set(tools) == {
        "list_sessions", "focus_session", "read_session_since", "search_session",
        "list_commands", "read_command_output",
    }
    assert set(tools["search_session"].inputSchema["properties"]) == {"pattern", "hostname", "max_matches"}
    assert tools["read_session_since"].inputSchema["required"] == ["byte_offset"]
    assert tools["read_command_output"].inputSchema["required"] == ["id"]


# ---------------------------------------------------------------------------
# Output cleaning
# ---------------------------------------------------------------------------

def test_clean_line_keeps_last_progress_frame():
    assert transcript.clean_line("\r\rprogress 1%\rprogress 2%\rprogress 3%\r\n") == "progress 3%"


def test_clean_line_applies_backspaces():
    assert transcript.clean_line("lss\b \b -la") == "ls -la"


def test_clean_line_strips_osc_title():
    assert transcript.clean_line("\x1b]0;me@box:~\x07me@box:~$ ls") == "me@box:~$ ls"


def test_compact_collapses_repeats_and_long_lines():
    long = "x" * (transcript.MAX_LINE_CHARS + 7)
    assert transcript.compact(["a", "ok", "ok", "ok", "b", long]) == [
        "a", "ok (x3)", "b", "x" * transcript.MAX_LINE_CHARS + "…[+7 chars]",
    ]


def test_focus_session_collapses_progress_and_repeats(sessions_dir):
    write_log(sessions_dir, "prod", "\r".join(f"{i}%" for i in range(100)) + "\n" + "ok\n" * 50)
    assert server.focus_session(hostname="prod")["content"] == "99%\nok (x50)"


def test_read_session_since_grep(sessions_dir):
    log = write_log(sessions_dir, "prod", "old error\n")
    offset = log.stat().st_size
    log.open("a").write("fine\nERROR: disk full\nfine\n")
    result = server.read_session_since(byte_offset=offset, hostname="prod", grep="error")
    assert result["new_content"] == "ERROR: disk full"
    assert result["matched_lines"] == 1
    assert result["lines_added"] == 3


def test_read_session_since_bad_grep(sessions_dir):
    write_log(sessions_dir, "prod", "x\n")
    assert "Invalid regex" in server.read_session_since(byte_offset=0, hostname="prod", grep="[")["error"]


# ---------------------------------------------------------------------------
# Prompt detection
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("line, cmd", [
    ("ubuntu@prod-db-1:~$ ls -la", "ls -la"),
    ("root@host:/var/log# tail -f syslog", "tail -f syslog"),
    ("[ec2-user@ip-10-0-0-1 ~]$ df -h", "df -h"),
    ("(venv) me@box:~/app$ pytest", "pytest"),
    ("me@box ~ % git status", "git status"),
    ("$ make", "make"),
    ("❯ cargo build", "cargo build"),
    ("ubuntu@prod-db-1:~$ ", ""),
    ("ubuntu@prod-db-1:~$", ""),
])
def test_prompt_lines(line, cmd):
    assert transcript.prompt_cmd(line, [transcript.PROMPT_RE]) == cmd


@pytest.mark.parametrize("line", ["total 48", "drwxr-xr-x 2 root root 4096 .", "user@example.com wrote:", ""])
def test_output_lines_are_not_prompts(line):
    assert transcript.prompt_cmd(line, [transcript.PROMPT_RE]) is None


def test_compile_prompt_regex_requires_cmd_group():
    assert transcript.compile_prompt_regex(r"^>>> (?P<cmd>.*)$").match(">>> 1+1").group("cmd") == "1+1"
    with pytest.raises(ValueError, match="cmd"):
        transcript.compile_prompt_regex(r"^>>> (.*)$")
    with pytest.raises(ValueError, match="invalid"):
        transcript.compile_prompt_regex(r"^(")


def test_custom_prompt_regex(sessions_dir, monkeypatch):
    monkeypatch.setattr(server, "CUSTOM_PROMPT_RE", transcript.compile_prompt_regex(r"^>>> (?P<cmd>.*)$"))
    write_log(sessions_dir, "prod", ">>> 1+1\n2\n$ ls\n>>> ")
    result = server.list_commands(hostname="prod")
    assert [c["cmd"] for c in result["commands"]] == ["1+1"]  # the default "$" prompt is off
    assert result["prompt"] == "custom"
    assert server.LEARNED_PROMPTS == {}


# ---------------------------------------------------------------------------
# list_commands / read_command_output (fixture is a real bash session from `script`)
# ---------------------------------------------------------------------------

@pytest.fixture
def bash_log(sessions_dir):
    log = sessions_dir / "prod-1000.log"
    log.write_bytes((FIXTURES / "bash-session.log").read_bytes())
    return log


def test_list_commands_splits_real_bash_session(bash_log):
    result = server.list_commands(hostname="prod")
    assert [c["cmd"] for c in result["commands"]] == [
        "ls /etc | head -3",
        'for i in $(seq 1 50); do printf "\\rprogress %d%%" $i; done; echo',
        'python3 -c "1/0"',
        "yes ok | head -20",
        "exit",
    ]
    by_cmd = {c["cmd"]: c for c in result["commands"]}
    assert by_cmd["ls /etc | head -3"]["output_lines"] == 3
    assert by_cmd['python3 -c "1/0"']["flags"] == [
        "Traceback (most recent call last):", "ZeroDivisionError: division by zero",
    ]
    assert by_cmd["yes ok | head -20"]["flags"] == []
    assert by_cmd["ls /etc | head -3"]["done"] is True
    assert result["byte_offset"] == bash_log.stat().st_size


def test_list_commands_is_much_smaller_than_raw_output(bash_log):
    commands = json.dumps(server.list_commands(hostname="prod"))
    raw = len(bash_log.read_bytes())
    assert len(commands) < raw / 2


def test_list_commands_since_offset_mid_prompt(bash_log):
    data = bash_log.read_bytes()
    # The prompt was printed before the last read; the command was typed after it.
    offset = data.index(b'$ python3') + 2
    result = server.list_commands(hostname="prod", since_byte_offset=offset)
    assert [c["cmd"] for c in result["commands"]] == ['python3 -c "1/0"', "yes ok | head -20", "exit"]


def test_list_commands_at_end_is_empty(bash_log):
    size = bash_log.stat().st_size
    assert server.list_commands(hostname="prod", since_byte_offset=size)["commands"] == []


def test_list_commands_continued_output(sessions_dir):
    log = write_log(sessions_dir, "prod", "me@box:~$ make\nbuilding a\n")
    offset = log.stat().st_size
    log.open("a").write("building b\nerror: b failed\nme@box:~$ ")
    (cmd,) = server.list_commands(hostname="prod", since_byte_offset=offset)["commands"]
    assert cmd["cmd"] == "(output continued)"
    assert cmd["done"] is True
    assert cmd["flags"] == ["error: b failed"]


MULTILINE = (
    "me@box:~$ { echo a\n"
    "> systemctl --failed\n"
    "> }\n"
    "a\n"
    "> not a continuation: output\n"
    "me@box:~$ "
)


def test_list_commands_multiline_command_is_not_output(sessions_dir):
    write_log(sessions_dir, "prod", MULTILINE)
    (cmd,) = server.list_commands(hostname="prod")["commands"]
    assert cmd["cmd"] == "{ echo a"
    assert cmd["output_lines"] == 2
    assert cmd["flags"] == []


def test_read_command_output_skips_multiline_command(sessions_dir):
    write_log(sessions_dir, "prod", MULTILINE)
    result = server.read_command_output(0, hostname="prod")
    assert result["content"] == "a\n> not a continuation: output"


def test_list_commands_rewound(bash_log):
    result = server.list_commands(hostname="prod", since_byte_offset=10**9)
    assert result["rewound"] is True
    assert len(result["commands"]) == 5


def test_list_commands_max(bash_log):
    result = server.list_commands(hostname="prod", max_commands=2)
    assert [c["cmd"] for c in result["commands"]] == ["yes ok | head -20", "exit"]
    assert result["omitted_commands"] == 3


def test_read_command_output(bash_log):
    ids = {c["cmd"]: c["id"] for c in server.list_commands(hostname="prod")["commands"]}
    progress = server.read_command_output(ids['for i in $(seq 1 50); do printf "\\rprogress %d%%" $i; done; echo'], hostname="prod")
    assert progress["content"] == "progress 50%"
    ls = server.read_command_output(ids["ls /etc | head -3"], hostname="prod")
    assert ls["content"] == "alsa\narch-audit\narch-release"
    assert ls["cmd"] == "ls /etc | head -3"
    yes = server.read_command_output(ids["yes ok | head -20"], hostname="prod")
    assert yes["content"] == "ok (x20)"
    assert yes["output_lines"] == 20


def test_read_command_output_head_tail(sessions_dir):
    write_log(sessions_dir, "prod", "$ seq 100\n" + "".join(f"{i}\n" for i in range(1, 101)) + "$ ")
    result = server.read_command_output(0, hostname="prod", head=2, tail=3)
    assert result["content"].splitlines() == ["1", "2", "… 95 lines omitted …", "98", "99", "100"]
    assert result["output_lines"] == 100


def test_read_command_output_grep(bash_log):
    ids = {c["cmd"]: c["id"] for c in server.list_commands(hostname="prod")["commands"]}
    result = server.read_command_output(ids['python3 -c "1/0"'], hostname="prod", grep="Error")
    assert result["content"] == "ZeroDivisionError: division by zero"
    assert result["matched_lines"] == 1


@pytest.mark.parametrize("bad_id", [-1, 5, 10**9])
def test_read_command_output_rejects_unknown_ids(bash_log, bad_id):
    assert "Unknown command id" in server.read_command_output(bad_id, hostname="prod")["error"]


def test_new_tools_respect_hostname_scoping(sessions_dir, monkeypatch):
    write_log(sessions_dir, "staging", "$ cat secret\nsecret\n")
    assert "Invalid hostname" in server.list_commands(hostname="../x")["error"]
    assert "Invalid hostname" in server.read_command_output(0, hostname="../x")["error"]
    monkeypatch.setattr(server, "DEFAULT_HOSTNAME", "prod")
    assert "restricted" in server.list_commands(hostname="staging")["error"]
    assert "restricted" in server.read_command_output(0, hostname="staging")["error"]


def test_new_tools_are_audited_without_content(bash_log, sessions_dir):
    (first, *_) = server.list_commands(hostname="prod")["commands"]
    server.read_command_output(first["id"], hostname="prod")
    records = read_audit(sessions_dir)
    assert [r["tool"] for r in records] == ["list_commands", "read_command_output"]
    assert records[0]["commands"] == 5
    assert records[1]["id"] == first["id"]
    assert "arch-audit" not in (sessions_dir / "audit.jsonl").read_text()


def test_focus_session_empty_log(sessions_dir):
    write_log(sessions_dir, "prod", "")
    result = server.focus_session(hostname="prod")
    assert result["content"] == ""
    assert result["total_lines"] == 0


# ---------------------------------------------------------------------------
# Prompt learning
# ---------------------------------------------------------------------------

def commands(hostname="prod", **kw):
    result = server.list_commands(hostname=hostname, **kw)
    return [c["cmd"] for c in result["commands"]], result["prompt"]


def test_learns_custom_prompt(sessions_dir):
    write_log(sessions_dir, "prod", "λ ~/app make\nbuilt\nλ ~/app ls\na b\nλ ~/app ")
    assert commands() == (["make", "ls"], "learned")


def test_learned_prompt_matches_other_directories(sessions_dir):
    log = write_log(sessions_dir, "prod", "λ ~/app make\nbuilt\nλ ~/app ")
    assert commands()[1] == "learned"
    offset = log.stat().st_size
    log.open("a").write("cd /tmp\nλ /tmp ls\nx\nλ /tmp ")
    assert commands(since_byte_offset=offset)[0] == ["cd /tmp", "ls"]


def test_prompt_with_clock_and_cwd(sessions_dir):
    log = write_log(sessions_dir, "prod", "[12:01:33] me ~ » uptime\nup 3 days\n[12:01:40] me ~ » ")
    assert commands() == (["uptime"], "learned")
    log.open("a").write("cd /var/log\n[13:22:05] me /var/log » tail syslog\nline\n[13:22:09] me /var/log » ")
    assert commands()[0] == ["uptime", "cd /var/log", "tail syslog"]


def test_unconfirmed_trailing_line_is_not_learned(sessions_dir):
    write_log(sessions_dir, "prod", "$ sudo ls\n[sudo] password for me: ")
    assert commands() == (["sudo ls"], "default")
    assert server.LEARNED_PROMPTS == {}


def test_repeated_password_prompt_is_not_learned(sessions_dir):
    write_log(sessions_dir, "prod", "$ ssh x\nPassword: \nPassword: \nPassword: ")
    assert commands()[1] == "default"


def test_nothing_learned_while_a_command_runs(sessions_dir):
    write_log(sessions_dir, "prod", "λ ~ make\nbuilding\n")
    assert commands() == (["(session start)"], "default")


def test_prompt_change_keeps_both_patterns(sessions_dir):
    log = write_log(sessions_dir, "prod", "pi ~ ▸ sudo -i\npi ~ ▸ ")
    assert commands()[1] == "learned"
    log.open("a").write("\nPI-ROOT ~ ▸▸ id\nuid=0\nPI-ROOT ~ ▸▸ ")
    assert commands()[0] == ["sudo -i", "id"]
    assert len(server.LEARNED_PROMPTS["prod-1000000.log"]) == 2


def test_learned_prompts_are_capped(sessions_dir):
    log = write_log(sessions_dir, "prod", "")
    for name in "abcde":
        log.open("a").write(f"{name}> x\n{name}> ")
        server.list_commands(hostname="prod")
        log.open("a").write("\n")
    assert len(server.LEARNED_PROMPTS["prod-1000000.log"]) == server.MAX_LEARNED_PROMPTS


def test_learned_text_is_escaped(sessions_dir):
    write_log(sessions_dir, "prod", "(.*)[x]+ go\nok\n(.*)[x]+ ")
    assert commands() == (["go"], "learned")
    assert not transcript.prompt_cmd("anything", server.LEARNED_PROMPTS["prod-1000000.log"])


def test_learns_real_bash_prompt(bash_log):
    bash_log.open("ab").write(b"\x1b]0;ubuntu@prod-db-1:~\x07\x1b[?2004hubuntu@prod-db-1:~$ ")
    cmds, prompt = commands()
    assert prompt == "learned"
    assert cmds[:3] == ["ls /etc | head -3", 'for i in $(seq 1 50); do printf "\\rprogress %d%%" $i; done; echo', 'python3 -c "1/0"']


def test_huge_line_does_not_hang(sessions_dir):
    log = write_log(sessions_dir, "prod", "λ ~ ls\nx\nλ ~ ")
    assert commands()[1] == "learned"
    log.open("a").write("cat big\n" + "a " * 500_000 + "\nλ ~ ")
    assert commands()[0] == ["ls", "cat big"]


@pytest.mark.parametrize("line", [
    "ls: cannot access '/nonexistent': No such file or directory",
    "bash: foo: command not found",
    "cp: cannot create regular file 'x': Permission denied",
])
def test_alert_lines(line):
    assert transcript.is_alert(line)


# ---------------------------------------------------------------------------
# Regressions from review
# ---------------------------------------------------------------------------

def test_command_being_typed_is_listed_once_entered(sessions_dir):
    log = write_log(sessions_dir, "prod", "u@h:~$ ls\na\nu@h:~$ rm -rf /tm")
    result = server.list_commands(hostname="prod")
    assert [c["cmd"] for c in result["commands"]] == ["ls"]
    log.open("a").write("p/x\nu@h:~$ ")
    cmds = server.list_commands(hostname="prod", since_byte_offset=result["byte_offset"])["commands"]
    assert [c["cmd"] for c in cmds] == ["rm -rf /tmp/x"]


def test_prompt_is_not_learned_while_the_log_is_still_being_written(sessions_dir, monkeypatch):
    monkeypatch.setattr(server, "LEARN_IDLE_SECONDS", 60)
    log = write_log(sessions_dir, "prod", "λ ~ ls -la\nx\nλ ~ ls ")  # user is typing "ls "
    assert commands()[1] == "default"
    old = log.stat().st_mtime - 120
    os.utime(log, (old, old))
    log.write_text("λ ~ ls -la\nx\nλ ~ ")
    os.utime(log, (old, old))
    assert commands() == (["ls -la"], "learned")


def test_known_prompt_with_typed_text_is_not_learned_again(sessions_dir):
    log = write_log(sessions_dir, "prod", "λ ~ ls -la\nx\nλ ~ ")
    assert commands()[1] == "learned"
    log.open("a").write("ls ")  # idle mid-typing
    commands()
    assert len(server.LEARNED_PROMPTS["prod-1000000.log"]) == 1


def test_prompt_starting_with_directory(sessions_dir):
    log = write_log(sessions_dir, "prod", "~/app $ cat prices\nwidget $ 5\ngadget $ 7\n~/app $ ")
    assert commands() == (["cat prices"], "learned")
    log.open("a").write("cd /etc\n/etc $ ls\nhosts\n/etc $ ")
    assert commands()[0] == ["cat prices", "cd /etc", "ls"]


@pytest.mark.parametrize("prompt, line, cmd", [
    ("user@host:~/work$ ", "user@host:/var/log$ tail x", "tail x"),
    ("[ec2-user@ip ~]$ ", "[ec2-user@ip /tmp]$ ls", "ls"),
    ("λ ~/app ", "λ /tmp make", "make"),
    ("~/app on main ❯ ", "/srv on main ❯ git pull", "git pull"),
])
def test_generalized_prompts(prompt, line, cmd):
    rx = transcript.generalize_prompt(prompt)
    assert transcript.prompt_cmd(line, [rx]) == cmd
    assert transcript.prompt_cmd("/usr/bin/ls", [rx]) is None


def test_path_only_prompt_is_not_generalized():
    assert transcript.generalize_prompt("~/app ") is None


def test_new_log_rewinds_list_commands(sessions_dir):
    write_log(sessions_dir, "prod", "u@h:~$ cat old\n" + "x\n" * 50 + "u@h:~$ ", timestamp=1)
    first = server.list_commands(hostname="prod")
    write_log(sessions_dir, "prod", "u@h:~$ echo new\n" + "y\n" * 200 + "u@h:~$ ", timestamp=2)
    result = server.list_commands(
        hostname="prod", since_byte_offset=first["byte_offset"], logfile=first["logfile"])
    assert result["rewound"] is True
    assert result["logfile"] == "prod-2.log"
    assert [c["cmd"] for c in result["commands"]] == ["echo new"]


def test_read_command_output_from_an_older_log(sessions_dir):
    write_log(sessions_dir, "prod", "u@h:~$ cat old\nold output\nu@h:~$ ", timestamp=1)
    (cmd,) = server.list_commands(hostname="prod")["commands"]
    write_log(sessions_dir, "prod", "u@h:~$ echo new\nnew output\nu@h:~$ ", timestamp=2)
    result = server.read_command_output(cmd["id"], hostname="prod", logfile="prod-1.log")
    assert (result["cmd"], result["content"]) == ("cat old", "old output")
    assert "Unknown logfile" in server.read_command_output(0, hostname="prod", logfile="../x.log")["error"]


def test_new_log_rewinds_read_session_since(sessions_dir):
    old = write_log(sessions_dir, "prod", "old\n", timestamp=1)
    write_log(sessions_dir, "prod", "new session output\n" * 3, timestamp=2)
    result = server.read_session_since(byte_offset=old.stat().st_size, hostname="prod", logfile=old.name)
    assert result["rewound"] is True
    assert "new session output" in result["content"]


def test_default_line_counts(sessions_dir):
    write_log(sessions_dir, "prod", "".join(f"{i}\n" for i in range(300)))
    assert len(server.focus_session(hostname="prod")["content"].splitlines()) == server.FOCUS_LINES
    assert len(server.read_session_since(byte_offset=0, hostname="prod")["new_content"].splitlines()) == 200


@pytest.mark.parametrize("line, alert", [
    ("=== 12 passed, 0 failed in 1.2s ===", False),
    ("errors: 0", False),
    ("Done. 0 errors, 0 warnings", False),
    ("=== 1 failed, 11 passed ===", True),
    ("1 failed, 0 errors", True),
    ("error: build failed", True),
])
def test_zero_counts_are_not_alerts(line, alert):
    assert transcript.is_alert(line) is alert


def test_search_session_requires_pattern(sessions_dir):
    write_log(sessions_dir, "prod", "x\n")
    assert server.search_session(pattern="", hostname="prod") == {"error": "pattern is required"}


def test_blank_runs_collapse_to_one_blank_line():
    assert transcript.compact(["a", "", "", "", "b"]) == ["a", "", "b"]


def test_read_command_output_labels_unprompted_output(sessions_dir):
    write_log(sessions_dir, "prod", "banner\n$ ls\nx\n$ ")
    assert server.read_command_output(0, hostname="prod")["cmd"] == "(session start)"


# ---------------------------------------------------------------------------
# Tool descriptions (what the model reads to pick a tool)
# ---------------------------------------------------------------------------

def test_every_tool_and_parameter_is_described():
    tools = asyncio.run(server.mcp.list_tools())
    assert {t.name for t in tools} == {
        "list_sessions", "focus_session", "read_session_since",
        "list_commands", "read_command_output", "search_session",
    }
    for tool in tools:
        assert len(tool.description or "") > 200, tool.name
        for name, prop in tool.inputSchema.get("properties", {}).items():
            assert prop.get("description"), f"{tool.name}.{name}"


# ---------------------------------------------------------------------------
# Hostile output
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("line", [
    "a@b:" + " " * 4000,
    "a@b " + " \t" * 2000,
    "[a@b " + " " * 4000 + "]",
    "(venv) a@b:" + " " * 4000 + "x",
], ids=["colon", "tabs", "brackets", "venv"])
def test_prompt_matching_stays_linear(sessions_dir, line):
    # 256 near-miss prompt lines fill the 1 MiB window; a regex that backtracks
    # quadratically takes about 25 s here.
    write_log(sessions_dir, "prod", "me@box:~$ cat x\n" + (line + "\n") * 256 + "me@box:~$ ")
    start = time.perf_counter()
    server.list_commands(hostname="prod")
    assert time.perf_counter() - start < 2


def test_search_session_cuts_long_matching_lines(sessions_dir):
    write_log(sessions_dir, "prod", "error " + "x" * 100_000 + "\n")
    (match,) = server.search_session("error", hostname="prod")["matches"]
    assert len(match["text"]) < transcript.MAX_LINE_CHARS + 20
    assert match["text"].endswith(" chars]")


# ---------------------------------------------------------------------------
# Logs larger than the read windows
# ---------------------------------------------------------------------------

def test_list_commands_drops_partial_first_line_of_window(sessions_dir, monkeypatch):
    monkeypatch.setattr(server, "TAIL_BYTES", 40)
    write_log(sessions_dir, "prod", "me@box:~$ make\n" + "x" * 30 + "\nme@box:~$ ls\na\nme@box:~$ ")
    result = server.list_commands(hostname="prod")
    assert [c["cmd"] for c in result["commands"]] == ["ls"]


def test_read_command_output_marks_output_past_the_window(sessions_dir, monkeypatch):
    monkeypatch.setattr(server, "OUTPUT_BYTES", 64)
    write_log(sessions_dir, "prod", "me@box:~$ yes\n" + "y\n" * 100 + "me@box:~$ ")
    result = server.read_command_output(0, hostname="prod")
    assert result["truncated"] is True
    assert result["output_lines"] < 100


def test_read_command_output_complete_output_is_not_truncated(sessions_dir, monkeypatch):
    monkeypatch.setattr(server, "OUTPUT_BYTES", 64)
    write_log(sessions_dir, "prod", "me@box:~$ ls\na\nme@box:~$ " + "z" * 200)
    assert "truncated" not in server.read_command_output(0, hostname="prod")


# ---------------------------------------------------------------------------
# Bracketed paste: input lines between the prompt and the command's start
# ---------------------------------------------------------------------------

ON, OFF = transcript.PASTE_ON, transcript.PASTE_OFF
PASTED = (
    f"{ON}me@box:~$ {{ echo a\r\n"
    "\rsystemctl --failed\r\n"
    "\r}\r\n"
    f"{OFF}\ra\r\n"
    f"{ON}me@box:~$ "
)


def test_pasted_block_is_not_output(sessions_dir):
    write_log(sessions_dir, "prod", PASTED)
    (cmd,) = server.list_commands(hostname="prod")["commands"]
    assert cmd["cmd"] == "{ echo a"
    assert cmd["output_lines"] == 1
    assert cmd["flags"] == []
    assert server.read_command_output(cmd["id"], hostname="prod")["content"] == "a"


def test_typed_command_output_is_kept(sessions_dir):
    write_log(sessions_dir, "prod", f"{ON}me@box:~$ ls\r\n{OFF}\rfailed.txt\r\n{ON}me@box:~$ ")
    (cmd,) = server.list_commands(hostname="prod")["commands"]
    assert cmd["output_lines"] == 1
    assert cmd["flags"] == ["failed.txt"]


def test_unclosed_paste_marker_marks_nothing():
    raw = [f"{ON}me@box:~$ vim", "line one", "line two"]
    assert transcript.clean_lines(raw) == ["me@box:~$ vim", "line one", "line two"]


def test_paste_markers_in_hostile_output_stay_linear(sessions_dir):
    write_log(sessions_dir, "prod", "me@box:~$ cat x\n" + f"{ON}x\n" * 100_000 + "me@box:~$ ")
    start = time.perf_counter()
    server.list_commands(hostname="prod")
    assert time.perf_counter() - start < 2
