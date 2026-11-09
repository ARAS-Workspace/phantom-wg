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

setup: creates what is missing and overwrites nothing. -f belongs to gen-keys,
setup-auth and setup-tls.
"""

from __future__ import annotations

from core.commands import argument
from core.runner import ToolError
from stack.dev.libs import auth, environment, keys, tls, wallet

ABOUT = "Create what is missing: keys, auth, TLS, wallet"
ARGUMENTS = (argument("--admin-username", default=auth.DEFAULT_USERNAME),)
USAGE = "setup [--admin-username <name>]"


def run(admin_username: str) -> None:
    if not environment.missing():
        raise ToolError(
            "Setup is already complete.\n"
            "  Start the stack: ./tools/dev.sh up\n"
            "  Start over:      ./tools/dev.sh hard-reset"
        )

    print("Full setup...")
    if not keys.present():
        keys.generate()
    if not auth.bootstrapped():
        auth.first_bootstrap(admin_username)
    if not tls.present():
        tls.generate()
    if not wallet.present():
        wallet.create()
    print("Setup complete.")
