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

add-superadmin: a superadmin account, created by the auth service of the running
stack. The password is typed on the terminal; the service applies its rules and
prints one result line with its exit code.
"""

from __future__ import annotations

from core.commands import argument
from core.runner import ToolError
from stack.prod.libs import auth, gates, host

ABOUT = "Add a superadmin account"
ARGUMENTS = (argument("username"),)
USAGE = "add-superadmin <username>"


def run(username: str) -> None:
    gates.enforce(host.DOCKER_GATES)
    if not auth.serving():
        raise ToolError("The auth service is not running. Start it: ./tools/prod.sh up")
    auth.add_superadmin(username, auth.read_password())
