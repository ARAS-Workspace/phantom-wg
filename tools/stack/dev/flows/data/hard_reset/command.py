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

hard-reset of the development environment: the stack, its volumes and what it
bound in container-data go, setup starts from nothing.
"""

from __future__ import annotations

from core.runner import ToolError
from stack.dev.libs import compose, data

ABOUT = "Wipe the stack, its volumes and container-data"


def _confirmed() -> bool:
    try:
        return input("Type 'yes' to confirm: ") == "yes"
    except EOFError:
        return False


def run() -> None:
    compose.require_down()

    print("This will destroy ALL data: secrets, auth DB, and Docker volumes.")
    if not _confirmed():
        raise ToolError("Aborted.")

    print("Stopping stack...")
    compose.run("down", "-v")

    print("Removing container-data...")
    data.wipe_bound()

    print("Hard reset complete. Run './tools/dev.sh setup' to start fresh.")
