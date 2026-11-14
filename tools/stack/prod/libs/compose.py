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

import time
from collections.abc import Mapping
from typing import NoReturn

from core import runner
from core.runner import ToolError

COMPOSE = ("docker", "compose")
DAEMON = "daemon"
STEADY_SECONDS = 10
SETTLE_LIMIT = 60


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


def _states() -> dict[str, str]:
    """Each container of the stack with its state and how often it restarted."""
    ids = capture("ps", "-aq").split()
    if not ids:
        return {}
    lines = runner.capture(["docker", "inspect", "--format", "{{.Name}} {{.State.Status}} {{.RestartCount}}", *ids])
    return {name.lstrip("/"): state for name, state in (line.split(maxsplit=1) for line in lines.splitlines())}


def settled() -> None:
    """A service that fails comes back and falls again: only time shows that it stays up."""
    print("Waiting for the services to settle...")
    states: dict[str, str] = {}
    steady = 0
    for _ in range(SETTLE_LIMIT):
        previous, states = states, _states()
        all_up = bool(states) and all(state.startswith("running ") for state in states.values())
        steady = steady + 1 if all_up and states == previous else 0
        if steady >= STEADY_SECONDS:
            return
        time.sleep(1)

    lines = [f"  {name}: {state}" for name, state in sorted(states.items())]
    raise ToolError("\n".join(["The services did not settle:", *lines, "Read them: ./tools/prod.sh logs"]))


def attach(*args: str) -> NoReturn:
    """Gives the terminal to a Compose command that stays on it."""
    runner.replace([*COMPOSE, *args])
