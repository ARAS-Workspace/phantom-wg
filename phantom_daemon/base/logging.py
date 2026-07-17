"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.

Root logging setup — handler, level, and third-party noise control.
"""

from __future__ import annotations

import logging

LOGGER_NAME = "phantom-daemon"

_FORMAT = "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
_DATEFMT = "%Y-%m-%d %H:%M:%S"

_LEVELS: dict[str, int] = {
    "critical": logging.CRITICAL,
    "error": logging.ERROR,
    "warning": logging.WARNING,
    "info": logging.INFO,
    "debug": logging.DEBUG,
}

_DEFAULT_LEVEL = "info"

# Dependency loggers that flood at DEBUG. Pinned to INFO so that
# PHANTOM_LOG_LEVEL=debug surfaces our own tracing, not the event loop's.
_THIRD_PARTY = ("asyncio", "httpx", "httpcore", "multipart", "urllib3")


def setup_logging(level: str = _DEFAULT_LEVEL) -> str:
    """Attach a stderr handler to the root logger and set the daemon level.

    Must run before the first log call — uvicorn's dictConfig only configures
    its own loggers ('uvicorn', 'uvicorn.error', 'uvicorn.access') and leaves
    root untouched. Without a root handler the 'phantom-daemon' logger falls
    back to logging.lastResort, which drops everything below WARNING and emits
    the bare message with no timestamp, level, or logger name.

    Unknown level names fall back to 'info' rather than raising: a typo in an
    env var must not stop the daemon from booting.

    Returns the normalised level name, suitable for passing to uvicorn.
    """
    normalised = level.strip().lower()
    unknown = normalised not in _LEVELS
    if unknown:
        normalised = _DEFAULT_LEVEL

    resolved = _LEVELS[normalised]
    logging.basicConfig(level=resolved, format=_FORMAT, datefmt=_DATEFMT)

    # Never let a dependency log below INFO, whatever our own level is.
    for name in _THIRD_PARTY:
        logging.getLogger(name).setLevel(max(resolved, logging.INFO))

    if unknown:
        logging.getLogger(LOGGER_NAME).warning(
            "Unknown log level %r — falling back to %r. Valid: %s",
            level, _DEFAULT_LEVEL, ", ".join(_LEVELS),
        )

    return normalised
