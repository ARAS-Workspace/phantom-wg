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

Docker Compose in the root: docker-compose.yml with the override of this host.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import NoReturn

from core import runner
from core.runner import ToolError

COMPOSE = ("docker", "compose")
DAEMON = "daemon"


def run(*args: str, env: Mapping[str, str] | None = None) -> None:
    """Runs a Compose command in front of the operator."""
    runner.stream([*COMPOSE, *args], env=env)


def capture(*args: str) -> str:
    """Runs a Compose command for what it prints."""
    return runner.capture([*COMPOSE, *args])


def running() -> bool:
    """True while a container of the stack runs."""
    return bool(capture("ps", "-q"))


def require_down() -> None:
    if running():
        raise ToolError("The stack is running. Stop it first: ./tools/prod.sh down")


def attach(*args: str) -> NoReturn:
    """Gives the terminal to a Compose command that stays on it."""
    runner.replace([*COMPOSE, *args])
