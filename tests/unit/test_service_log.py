"""auth_service.__main__: the service logger on stdout, no uvicorn access log."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import auth_service.__main__ as entry
from auth_service.config import load_auth_config

ROOT = Path(__file__).resolve().parents[2]

# dictConfig runs in a child process: in this one it would turn off the
# propagation of phantom-auth, and caplog in other tests would see nothing.
PROBE = """
import logging
import logging.config

from auth_service.__main__ import log_config

logging.config.dictConfig(log_config("info"))
log = logging.getLogger("phantom-auth")
log.debug("below the level")
log.info("Auth keys loaded")
log.warning('login_failed ip=203.0.113.5 username="x"')
"""


def test_main_passes_the_service_logger_and_no_access_log(monkeypatch):
    seen = {}
    monkeypatch.setattr(entry.uvicorn, "run", lambda _app, **kwargs: seen.update(kwargs))
    entry.main()
    level = load_auth_config().log_level
    assert seen["access_log"] is False
    assert seen["log_level"] == level
    assert seen["log_config"] == entry.log_config(level)


def test_the_service_logger_writes_time_level_and_name_to_stdout():
    done = subprocess.run([sys.executable, "-c", PROBE], cwd=ROOT,
                          capture_output=True, text=True, check=True)
    # asctime is "YYYY-mm-dd HH:MM:SS,mmm": the third field starts the level.
    assert [line.split(" ", 2)[2] for line in done.stdout.splitlines()] == [
        "INFO phantom-auth Auth keys loaded",
        'WARNING phantom-auth login_failed ip=203.0.113.5 username="x"',
    ]
    assert done.stderr == ""


def test_the_uvicorn_loggers_are_kept():
    config = entry.log_config("info")
    assert {"uvicorn", "uvicorn.error", "uvicorn.access"} <= set(config["loggers"])
    assert config["loggers"]["phantom-auth"] == {
        "handlers": ["phantom"], "level": "INFO", "propagate": False,
    }
