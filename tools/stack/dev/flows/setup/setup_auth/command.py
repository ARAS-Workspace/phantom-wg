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

setup-auth: the auth service.
"""

from __future__ import annotations

from core.commands import FORCE, argument
from stack.dev.libs import auth

ABOUT = "Bootstrap auth service"
ARGUMENTS = (FORCE, argument("--username", default=auth.DEFAULT_USERNAME))
USAGE = "setup-auth [-f] [--username <name>]"


def run(force: bool, username: str) -> None:
    archived = ""
    if auth.database().is_file():
        if force:
            archived = auth.archive()
        elif auth.bootstrapped():
            print("Auth service already bootstrapped. Use -f to overwrite.")
            return
        else:
            auth.first_bootstrap()

    auth.bootstrap(username)
    if archived:
        print(f"  Previous: {archived}")
        print("Restart auth-service if the stack is running.")
