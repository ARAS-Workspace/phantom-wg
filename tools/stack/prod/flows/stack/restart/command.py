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

restart: all services, or one of them.
"""

from __future__ import annotations

from core.commands import argument
from core.runner import ToolError
from stack.prod.libs import compose

ABOUT = "Restart all or one service"
ARGUMENTS = (argument("service", nargs="?"),)
USAGE = "restart [service]"


def run(service: str | None) -> None:
    if not compose.running():
        raise ToolError("The stack is not running. Start it: ./tools/prod.sh up")

    print(f"Restarting {service or 'all services'}...")
    compose.run("restart", *([service] if service else []))
    print("Restarted.")
