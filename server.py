#!/usr/bin/env python3
import re
from datetime import datetime, timezone
from pathlib import Path

from mcp.server.fastmcp import FastMCP

SESSIONS_DIR = Path("/sessions")
TAIL_LINES = 200
ANSI_RE = re.compile(r'\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')

mcp = FastMCP("ssh-companion-mcp")


def strip_ansi(s: str) -> str:
    return ANSI_RE.sub("", s)


def _logs_for(hostname: str) -> list[Path]:
    """Return all log files for a hostname, sorted oldest-first."""
    return sorted(SESSIONS_DIR.glob(f"{hostname}-*.log"))


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


@mcp.tool()
def list_sessions() -> list[dict]:
    """List all captured SSH sessions grouped by hostname."""
    if not SESSIONS_DIR.exists():
        return []

    groups: dict[str, list[Path]] = {}
    for log in SESSIONS_DIR.glob("*.log"):
        host = _hostname_from_path(log)
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
def focus_session(hostname: str, lines: int = TAIL_LINES) -> dict:
    """
    Read the most recent session log for a hostname.
    Returns the last N lines of clean (ANSI-stripped) output plus a byte_offset
    you can pass to read_session_since for efficient polling.
    """
    log = _latest_log(hostname)
    if log is None:
        return {"error": f"No session logs found for hostname '{hostname}'"}

    raw = log.read_bytes().decode("utf-8", errors="replace")
    clean_lines = [strip_ansi(l) for l in raw.splitlines()]
    tail = "\n".join(clean_lines[-lines:])

    stat = log.stat()
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
def read_session_since(hostname: str, byte_offset: int, lines: int = TAIL_LINES) -> dict:
    """
    Return only new output since the last read (pass byte_offset from focus_session
    or a previous read_session_since call). Use this for polling / /loop watch mode.
    """
    log = _latest_log(hostname)
    if log is None:
        return {"error": f"No session logs found for hostname '{hostname}'"}

    size = log.stat().st_size

    if byte_offset > size:
        # log was replaced / rotated — return full content
        return {**focus_session(hostname, lines), "rewound": True}

    if byte_offset == size:
        return {
            "hostname": hostname,
            "logfile": log.name,
            "new_content": "",
            "byte_offset": size,
            "lines_added": 0,
        }

    with log.open("rb") as f:
        f.seek(byte_offset)
        chunk = f.read().decode("utf-8", errors="replace")

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
def search_session(hostname: str, pattern: str, max_matches: int = 50) -> dict:
    """
    Search all session logs for a hostname using a Python regex pattern.
    Useful for finding errors, specific commands, or events across the full history.
    """
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
        raw = log.read_bytes().decode("utf-8", errors="replace")
        for i, line in enumerate(raw.splitlines(), 1):
            clean = strip_ansi(line)
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
    mcp.run(transport="stdio")
