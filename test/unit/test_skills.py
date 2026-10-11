import re
import subprocess
from pathlib import Path

SKILL = Path(__file__).parents[2] / ".claude" / "skills" / "ssh-perf" / "SKILL.md"


def baseline_block() -> str:
    text = SKILL.read_text()
    section = text[text.index("## Baseline block"):]
    return re.search(r"```\n(.*?)```", section, re.S).group(1)


def test_perf_baseline_block_is_valid_bash():
    subprocess.run(["bash", "-n"], input=baseline_block(), text=True, check=True)


def test_perf_baseline_block_is_one_command():
    # Pasted lines typed ahead of a running command never get a prompt, so
    # list_commands would miss them; braces make the block a single command.
    block = baseline_block().strip()
    assert block.startswith("{ ") and block.endswith("} 2>&1")


def test_perf_baseline_block_fits_a_narrow_pane():
    # Claude Code wraps long lines with real line breaks, so a line wider than
    # the Claude pane would be copied broken in two.
    assert max(len(line) for line in baseline_block().splitlines()) <= 60
