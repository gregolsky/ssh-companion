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

"""Turning raw terminal output into text worth sending to the model: cleaning
lines, spotting shell prompts and error lines, and grouping lines into commands.
Pure functions only; reading the session logs is server.py's job."""

import re

# OSC sequences (e.g. the window title bash sets before each prompt) first, so
# their payload goes too; then CSI and two-byte escapes.
ANSI_RE = re.compile(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
MAX_LINE_CHARS = 500
MAX_FLAGS = 3

# A shell prompt followed by what the user typed. Matches "user@host:~$ cmd",
# "[user@host dir]# cmd", zsh-style "user@host ~ % cmd", an optional "(venv) "
# prefix, and bare "$ cmd" / "# cmd" / "❯ cmd". The text after the prompt goes
# in the "cmd" group; an empty cmd (just Enter) still ends the previous command.
# No two adjacent parts may match the same characters (the directory part
# already takes spaces), or hostile output makes matching quadratic.
DEFAULT_PROMPT_RE = (
    r"^(?:\(\S+\)\s*)?"
    r"(?:\[?[\w.-]+@[\w.-]+[: ][^\]$#%>]*(?:\]\s*)?[$#%>]|[$#❯%])"
    r"(?:\s+(?P<cmd>.*?))?\s*$"
)
PROMPT_RE = re.compile(DEFAULT_PROMPT_RE)
# Longer lines are never treated as prompt lines, which bounds regex work.
MAX_PROMPT_LINE = 4096
# The rest of a multi-line command, echoed after the shell's "> " (PS2) prompt.
CONTINUATION_PREFIX = "> "
# Bracketed paste: shells such as bash 5.1+ turn it on when printing the prompt
# and off when the command starts, so the lines in between are the user's input
# (a pasted block is echoed without any PS2 prompt).
PASTE_ON = "\x1b[?2004h"
PASTE_OFF = "\x1b[?2004l"

# Output lines worth a look without reading the whole output.
ALERT_RE = re.compile(
    r"error|fail(?:ed|ure)?\b|panic|traceback|\bkilled\b|out of memory|oom-kill|segfault"
    r"|permission denied|refused|timed out|no space left|command not found|no such file|cannot "
    r"|exit (?:code|status):? *[1-9]",
    re.IGNORECASE,
)
# "0 failed", "errors: 0": summaries that report nothing went wrong.
ZERO_COUNT_RE = re.compile(
    r"\b0 (?:errors?|fail(?:ed|ures?)|warnings?)\b|\b(?:errors?|fail(?:ed|ures?))\s*[:=]\s*0\b",
    re.IGNORECASE,
)


def strip_ansi(s: str) -> str:
    return ANSI_RE.sub("", s)


def clean_line(line: str) -> str:
    """One terminal line as it looked on screen: no ANSI codes, carriage-return
    overwrites (progress bars) and backspaces applied."""
    line = strip_ansi(line.rstrip("\r\n"))
    if "\r" in line:
        segments = [seg for seg in line.split("\r") if seg]
        line = segments[-1] if segments else ""
    if "\b" in line:
        out: list[str] = []
        for ch in line:
            if ch == "\b":
                if out:
                    out.pop()
            else:
                out.append(ch)
        line = "".join(out)
    return line


def clean_lines(raw: list[str]) -> list[str]:
    """clean_line for consecutive raw lines; lines the user typed or pasted
    after a prompt (see PASTE_ON) get CONTINUATION_PREFIX, like PS2 lines."""
    lines = [clean_line(r) for r in raw]
    # next_off[i]: index of the first line at or after i where input ends.
    next_off = [len(raw)] * (len(raw) + 1)
    for i in range(len(raw) - 1, -1, -1):
        next_off[i] = i if PASTE_OFF in raw[i] else next_off[i + 1]
    i = 0
    while i < len(raw):
        on = raw[i].rfind(PASTE_ON)
        end = next_off[i + 1]
        if on != -1 and raw[i].rfind(PASTE_OFF) < on and end < len(raw):
            for k in range(i + 1, end):
                lines[k] = CONTINUATION_PREFIX + lines[k]
            i = end
        else:
            i += 1
    return lines


def compact(lines: list[str]) -> list[str]:
    """Collapse runs of identical lines (blank runs to one blank line) and cut
    overlong ones."""
    out: list[str] = []
    prev, count = None, 0
    for line in lines + [None]:
        if line == prev:
            count += 1
            continue
        if prev is not None:
            out.append(prev if count == 1 or not prev.strip() else f"{prev} (x{count})")
        prev, count = line, 1
    return [
        l if len(l) <= MAX_LINE_CHARS else f"{l[:MAX_LINE_CHARS]}…[+{len(l) - MAX_LINE_CHARS} chars]"
        for l in out
    ]


def render(lines: list[str]) -> str:
    return "\n".join(compact(lines))


def is_alert(line: str) -> bool:
    return bool(ALERT_RE.search(ZERO_COUNT_RE.sub("", line)))


def compile_prompt_regex(pattern: str) -> re.Pattern:
    """Compile a user-supplied --prompt-regex."""
    try:
        rx = re.compile(pattern)
    except re.error as e:
        raise ValueError(f"invalid --prompt-regex: {e}") from e
    if "cmd" not in rx.groupindex:
        raise ValueError("--prompt-regex needs a (?P<cmd>...) group for the typed command")
    return rx


def prompt_cmd(line: str, matchers: list[re.Pattern]) -> str | None:
    """The command typed after a prompt, "" for a bare prompt, None for output."""
    if len(line) > MAX_PROMPT_LINE:
        return None
    for rx in matchers:
        m = rx.match(line)
        if m:
            return (m.group("cmd") or "").strip()
    return None


def _literal(s: str) -> str:
    """re.escape, except digit runs match any number (clocks, counters, host-1)."""
    return "".join(r"\d+" if part.isdigit() else re.escape(part) for part in re.split(r"(\d+)", s))


def generalize_prompt(prompt: str) -> re.Pattern | None:
    """Turn one observed prompt into a pattern that also matches it in other
    directories, with the typed command in the "cmd" group. The directory is the
    whitespace-free token starting at the first "~" or "/"; symbols closing that
    token ("$", "]$", "#") stay literal. Returns None when nothing but a path
    would be left to anchor on."""
    body = prompt.rstrip()
    if not body:
        return None
    cwd = re.search(r"[~/]", body)
    if cwd is None:
        core = _literal(body)
    else:
        end = re.search(r"\s|$", body[cwd.start():]).start() + cwd.start()
        head, token, rest = body[:cwd.start()], body[cwd.start():end], body[end:]
        tail = re.search(r"[^A-Za-z0-9~/._-]+$", token)  # "$", "]$", "#", "❯", "λ", ...
        if not (head.strip() or tail or rest.strip()):
            return None
        path = r"[~/]\S*?" + _literal(tail.group()) if tail else r"[~/]\S*"
        core = _literal(head) + path + _literal(rest)
    return re.compile("^" + core + r"(?:\s+(?P<cmd>.*?))?\s*$")


def split_commands(lines: list[tuple[int, str]], start: int, matchers: list[re.Pattern]) -> list[dict]:
    """Group (offset, line) pairs into commands: a prompt line plus the output up
    to the next prompt. start is the log offset the lines were read from."""
    commands: list[dict] = []
    current: dict | None = None
    continuing = False
    for offset, line in lines:
        cmd = prompt_cmd(line, matchers)
        if cmd is not None:
            if current:
                current["done"] = True
            current = None
            if cmd:
                current = {"id": offset, "cmd": cmd, "output_lines": 0, "flags": [], "done": False}
                commands.append(current)
            continuing = bool(cmd)
            continue
        if continuing and line.startswith(CONTINUATION_PREFIX):
            continue  # part of the command line, not its output
        continuing = False
        if current is None:
            if not line.strip():
                continue
            current = {"id": offset, "cmd": unprompted_label(start), "output_lines": 0, "flags": [], "done": False}
            commands.append(current)
        if not current["output_lines"] and not line.strip():
            continue  # blank line the shell prints after the command echo
        current["output_lines"] += 1
        if len(current["flags"]) < MAX_FLAGS and is_alert(line):
            current["flags"].append(line.strip()[:200])
    return commands


def unprompted_label(offset: int) -> str:
    """What to call output that has no prompt line before it."""
    return "(session start)" if offset == 0 else "(output continued)"
