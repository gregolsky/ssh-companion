import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(REPO_ROOT))

import server  # noqa: E402


@pytest.fixture(autouse=True)
def reset_server_globals(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "SESSIONS_DIR", tmp_path)
    monkeypatch.setattr(server, "DEFAULT_HOSTNAME", "")
    monkeypatch.setattr(server, "CUSTOM_PROMPT_RE", None)
    monkeypatch.setattr(server, "LEARNED_PROMPTS", {})
    monkeypatch.setattr(server, "LEARN_IDLE_SECONDS", 0)


@pytest.fixture
def sessions_dir(tmp_path):
    return tmp_path


def write_log(sessions_dir: Path, hostname: str, content: str, timestamp: int = 1000000) -> Path:
    log = sessions_dir / f"{hostname}-{timestamp}.log"
    log.write_text(content)
    return log
