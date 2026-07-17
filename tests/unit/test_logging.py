"""Tests for phantom_daemon.base.logging — root handler and level setup."""

from __future__ import annotations

import logging

import pytest

from phantom_daemon.base.logging import LOGGER_NAME, setup_logging


@pytest.fixture(autouse=True)
def _restore_logging():
    """Undo setup_logging's global mutations after each test."""
    root = logging.getLogger()
    saved_handlers = root.handlers[:]
    saved_level = root.level
    saved_third_party = {
        n: logging.getLogger(n).level
        for n in ("asyncio", "httpx", "httpcore", "multipart", "urllib3")
    }
    yield
    root.handlers[:] = saved_handlers
    root.setLevel(saved_level)
    for name, lvl in saved_third_party.items():
        logging.getLogger(name).setLevel(lvl)


def _reset_root() -> None:
    """basicConfig is a no-op if root already has handlers."""
    root = logging.getLogger()
    root.handlers[:] = []


class TestSetupLogging:
    def test_attaches_root_handler(self):
        _reset_root()
        setup_logging("info")
        assert logging.getLogger().handlers, "root must get a handler"

    def test_daemon_logger_emits_at_info(self):
        """The whole point: without setup_logging, log.info() is a no-op."""
        _reset_root()
        setup_logging("info")
        assert logging.getLogger(LOGGER_NAME).isEnabledFor(logging.INFO)

    def test_debug_enables_debug(self):
        _reset_root()
        setup_logging("debug")
        assert logging.getLogger(LOGGER_NAME).isEnabledFor(logging.DEBUG)

    def test_warning_suppresses_info(self):
        _reset_root()
        setup_logging("warning")
        log = logging.getLogger(LOGGER_NAME)
        assert not log.isEnabledFor(logging.INFO)
        assert log.isEnabledFor(logging.WARNING)

    def test_returns_normalised_level(self):
        _reset_root()
        assert setup_logging("DEBUG") == "debug"
        _reset_root()
        assert setup_logging("  Info  ") == "info"

    def test_unknown_level_falls_back_to_info(self):
        """A typo in an env var must not stop the daemon from booting."""
        _reset_root()
        assert setup_logging("verbose") == "info"
        assert logging.getLogger(LOGGER_NAME).isEnabledFor(logging.INFO)

    def test_third_party_stays_at_info_under_debug(self):
        """PHANTOM_LOG_LEVEL=debug must not unleash asyncio's event-loop spam."""
        _reset_root()
        setup_logging("debug")
        assert not logging.getLogger("asyncio").isEnabledFor(logging.DEBUG)
        assert logging.getLogger("asyncio").isEnabledFor(logging.INFO)

    def test_third_party_follows_level_above_info(self):
        _reset_root()
        setup_logging("warning")
        assert not logging.getLogger("asyncio").isEnabledFor(logging.INFO)
