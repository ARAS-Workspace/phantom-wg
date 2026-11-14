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

update: the latest release on this host.

The clone pulls it, then the tool starts again: the new code runs its own hook,
checks and stack.
"""

from __future__ import annotations

from pathlib import Path

from core import runner
from core.commands import argument
from core.runner import ToolError
from stack.prod.libs import compose, environment, gates, host, images, install

ABOUT = "Update to the latest release"
ARGUMENTS = (argument("--pulled", action="store_true"),)
USAGE = "update"

HOOK = Path(__file__).resolve().parent / "helper" / "update_hook.sh"
ENTRY = "tools/prod.sh"


def _pull() -> None:
    gates.enforce(host.UPDATE_GATES)
    if not install.clone():
        raise ToolError("This install has no git remote: update has nothing to follow.")
    install.pull()
    runner.replace([str(runner.ROOT / ENTRY), "update", "--pulled"])


def _apply() -> None:
    images.sync()
    runner.stream(["bash", str(HOOK)])
    environment.require()
    compose.run("config", "-q")

    # The source is bind-mounted: every service starts again, changed or not.
    print("Recreating stack...")
    compose.run("up", "-d", "--force-recreate")
    compose.settled()

    compose.run("ps")
    print("Update complete.")


def run(pulled: bool) -> None:
    if not pulled:
        _pull()
    _apply()
