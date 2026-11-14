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

hard-reset: the data of the install is wiped; the env files, the override and
the Cloudflare mode stay.
"""

from __future__ import annotations

from core.runner import ToolError
from stack.prod.libs import compose, data, gates, host, images

ABOUT = "Wipe ALL data (secrets + auth DB + volumes)"


def _confirmed() -> bool:
    try:
        return input("Type 'yes' to confirm: ") == "yes"
    except EOFError:
        return False


def run() -> None:
    gates.enforce(host.DOCKER_GATES)
    compose.require_down()

    print("This will destroy ALL data: secrets, auth DB, and Docker volumes.")
    if not _confirmed():
        raise ToolError("Aborted.")

    targets = data.holding_files()
    image = images.ensure(compose.DAEMON) if targets else ""

    print("Stopping stack...")
    compose.run("down", "-v")

    print("Removing container-data...")
    if targets:
        data.wipe(targets, image)

    print("Hard reset complete. Run './tools/prod.sh setup' to start fresh.")
