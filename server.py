#!/usr/bin/env python3
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

import argparse
import functools
import glob
import inspect
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from mcp.server.fastmcp import FastMCP

SESSIONS_DIR = Path("/sessions")
TAIL_LINES = 200
MAX_LINES = 2000
MAX_MATCHES = 500
MAX_PATTERN_LEN = 500
TAIL_BYTES = 1024 * 1024
# Hostnames come from the model (and, indirectly, from remote session output),
# so they must never carry path separators or glob metacharacters.
HOSTNAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
ANSI_RE = re.compile(r'\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')

DEFAULT_HOSTNAME = ""

mcp = FastMCP("ssh-companion")


def strip_ansi(s: str) -> str:
    return ANSI_RE.sub("", s)


def _log_ts(path: Path) -> int:
    m = re.search(r"-(\d+)\.log$", path.name)
    return int(m.group(1)) if m else 0


def _logs_for(hostname: str) -> list[Path]:
    """Return all log files for exactly this hostname, sorted oldest-first."""
    logs = [
        p for p in SESSIONS_DIR.glob(f"{glob.escape(hostname)}-*.log")
        if _hostname_from_path(p) == hostname
    ]
    return sorted(logs, key=_log_ts)


def _latest_log(hostname: str) -> Path | None:
    logs = _logs_for(hostname)
    return logs[-1] if logs else None


def _hostname_from_path(path: Path) -> str:
    """prod-db-1-1713345600.log -> prod-db-1"""
    name = path.stem  # strip .log
    # strip trailing -<digits> timestamp
    return re.sub(r"-\d+$", "", name)


def _ts_to_iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def _resolve_hostname(hostname: str) -> tuple[str, str | None]:
    """Return (hostname, error). Enforces --hostname scoping and the name allowlist."""
    hostname = hostname or DEFAULT_HOSTNAME
    if not hostname:
        return "", "hostname is required"
    if DEFAULT_HOSTNAME and hostname != DEFAULT_HOSTNAME:
        return "", f"This server is restricted to hostname '{DEFAULT_HOSTNAME}'"
    if not HOSTNAME_RE.match(hostname):
        return "", f"Invalid hostname '{hostname}'"
    return hostname, None


def _clamp(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, value))


# Result fields worth keeping in the audit log. Session content never goes in.
AUDIT_RESULT_FIELDS = (
    "hostname", "logfile", "error", "total_lines", "lines_added",
    "byte_offset", "rewound", "truncated", "total_searched_lines",
)


def _audit(record: dict) -> None:
    """Append one JSON line to <sessions>/audit.jsonl. Never raises."""
    try:
        fd = os.open(SESSIONS_DIR / "audit.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            # One write per record so appends from several servers don't interleave.
            os.write(fd, (json.dumps(record, ensure_ascii=False) + "\n").encode())
        finally:
            os.close(fd)
    except OSError as e:
        print(f"ssh-companion: could not write audit log: {e}", file=sys.stderr)


def _audited(fn):
    """Record every call of an MCP tool (who asked for what, and the outcome)."""
    sig = inspect.signature(fn)

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        record = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "event": "mcp_tool",
            "tool": fn.__name__,
            "server_hostname": DEFAULT_HOSTNAME,
            "args": dict(sig.bind(*args, **kwargs).arguments),
        }
        try:
            result = fn(*args, **kwargs)
        except Exception as e:
            record.update(ok=False, error=f"{type(e).__name__}: {e}")
            _audit(record)
            raise
        if isinstance(result, dict):
            record["ok"] = "error" not in result
            record.update({k: result[k] for k in AUDIT_RESULT_FIELDS if k in result})
            if "matches" in result:
                record["matches"] = len(result["matches"])
        else:
            record["ok"] = True
            record["sessions"] = len(result)
        _audit(record)
        return result

    return wrapper


@mcp.tool()
@_audited
def list_sessions() -> list[dict]:
    """List captured SSH sessions. When the server is started with --hostname it lists only that host's sessions."""
    if not SESSIONS_DIR.exists():
        return []

    groups: dict[str, list[Path]] = {}
    for log in SESSIONS_DIR.glob("*.log"):
        host = _hostname_from_path(log)
        if DEFAULT_HOSTNAME and host != DEFAULT_HOSTNAME:
            continue
        groups.setdefault(host, []).append(log)

    result = []
    for host, logs in sorted(groups.items()):
        latest = max(logs, key=lambda p: p.stat().st_mtime)
        total_kb = sum(p.stat().st_size for p in logs) // 1024
        result.append({
            "hostname": host,
            "log_count": len(logs),
            "last_active": _ts_to_iso(latest.stat().st_mtime),
            "size_kb": total_kb,
        })
    return result


@mcp.tool()
@_audited
def focus_session(hostname: str = "", lines: int = TAIL_LINES) -> dict:
    """
    Read the most recent session log for a hostname.
    Returns the last N lines (max 2000) of clean (ANSI-stripped) output plus a byte_offset
    you can pass to read_session_since for efficient polling. Only the last 1 MiB of
    the log is read, so total_lines counts lines within that window.
    Hostname defaults to the server's --hostname value when not provided.
    """
    hostname, err = _resolve_hostname(hostname)
    if err:
        return {"error": err}
    return _focus(hostname, lines)


def _focus(hostname: str, lines: int) -> dict:
    lines = _clamp(lines, 1, MAX_LINES)
    log = _latest_log(hostname)
    if log is None:
        return {"error": f"No session logs found for hostname '{hostname}'"}

    stat = log.stat()
    with log.open("rb") as f:
        start = max(0, stat.st_size - TAIL_BYTES)
        f.seek(start)
        data = f.read(stat.st_size - start)
    raw = data.decode("utf-8", errors="replace")
    clean_lines = [strip_ansi(l) for l in raw.splitlines()]
    if start > 0 and clean_lines:
        clean_lines = clean_lines[1:]  # first line is likely partial
    tail = "\n".join(clean_lines[-lines:])

    ts_match = re.search(r"-(\d+)\.log$", log.name)
    session_start = _ts_to_iso(int(ts_match.group(1))) if ts_match else _ts_to_iso(stat.st_ctime)

    return {
        "hostname": hostname,
        "logfile": log.name,
        "content": tail,
        "total_lines": len(clean_lines),
        "byte_offset": stat.st_size,
        "session_start": session_start,
    }


@mcp.tool()
@_audited
def read_session_since(byte_offset: int, hostname: str = "", lines: int = TAIL_LINES) -> dict:
    """
    Return only new output since the last read (pass byte_offset from focus_session
    or a previous read_session_since call). Use this for polling / /loop watch mode.
    Hostname defaults to the server's --hostname value when not provided.
    """
    hostname, err = _resolve_hostname(hostname)
    if err:
        return {"error": err}
    if byte_offset < 0:
        return {"error": "byte_offset must be >= 0"}
    lines = _clamp(lines, 1, MAX_LINES)
    log = _latest_log(hostname)
    if log is None:
        return {"error": f"No session logs found for hostname '{hostname}'"}

    size = log.stat().st_size

    if byte_offset > size:
        # log was replaced / rotated — return full content
        return {**_focus(hostname, lines), "rewound": True}

    if byte_offset == size:
        return {
            "hostname": hostname,
            "logfile": log.name,
            "new_content": "",
            "byte_offset": size,
            "lines_added": 0,
        }

    with log.open("rb") as f:
        f.seek(max(byte_offset, size - TAIL_BYTES))
        chunk = f.read(size - f.tell()).decode("utf-8", errors="replace")

    new_lines = [strip_ansi(l) for l in chunk.splitlines()]
    tail = "\n".join(new_lines[-lines:]) if len(new_lines) > lines else "\n".join(new_lines)

    return {
        "hostname": hostname,
        "logfile": log.name,
        "new_content": tail,
        "byte_offset": size,
        "lines_added": len(new_lines),
    }


@mcp.tool()
@_audited
def search_session(pattern: str, hostname: str = "", max_matches: int = 50) -> dict:
    """
    Search all session logs for a hostname using a Python regex pattern.
    Useful for finding errors, specific commands, or events across the full history.
    Hostname defaults to the server's --hostname value when not provided.
    """
    hostname, err = _resolve_hostname(hostname)
    if err:
        return {"error": err}
    if len(pattern) > MAX_PATTERN_LEN:
        return {"error": f"Pattern too long (max {MAX_PATTERN_LEN} characters)"}
    max_matches = _clamp(max_matches, 1, MAX_MATCHES)
    try:
        rx = re.compile(pattern, re.IGNORECASE)
    except re.error as e:
        return {"error": f"Invalid regex: {e}"}

    logs = _logs_for(hostname)
    if not logs:
        return {"error": f"No session logs found for hostname '{hostname}'"}

    matches = []
    total_lines = 0

    for log in logs:
        with log.open("rb") as f:
            for i, raw_line in enumerate(f, 1):
                clean = strip_ansi(raw_line.decode("utf-8", errors="replace").rstrip("\r\n"))
                total_lines += 1
                if rx.search(clean):
                    matches.append({
                        "logfile": log.name,
                        "line_no": i,
                        "text": clean.strip(),
                    })
                    if len(matches) >= max_matches:
                        break
        if len(matches) >= max_matches:
            break

    return {
        "hostname": hostname,
        "pattern": pattern,
        "matches": matches,
        "total_searched_lines": total_lines,
        "truncated": len(matches) >= max_matches,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--hostname", default="", help="Restrict this MCP instance to one SSH host")
    args = parser.parse_args()
    DEFAULT_HOSTNAME = args.hostname
    mcp.run(transport="stdio")
