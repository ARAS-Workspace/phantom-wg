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

setup-auth: the keys and the database of the auth service.
"""

from __future__ import annotations

from core.commands import FORCE, argument
from stack.prod.libs import auth, gates, host

ABOUT = "Bootstrap auth service"
ARGUMENTS = (FORCE, argument("--admin-username", default=auth.DEFAULT_USERNAME))
USAGE = "setup-auth [-f] [--admin-username <name>]"


def run(force: bool, admin_username: str) -> None:
    gates.enforce(host.DOCKER_GATES)
    exists = auth.database().is_file()
    if exists and not force:
        if auth.bootstrapped():
            print("Auth service already bootstrapped. Use -f to overwrite.")
            return
        auth.first_bootstrap()

    image = auth.ready()
    archived = auth.archive() if exists else ""
    auth.bootstrap(image, admin_username)
    if archived:
        print(f"  Previous: {archived}")
