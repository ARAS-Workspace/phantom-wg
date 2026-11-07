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

setup-tls: a self-signed TLS certificate.
"""

from __future__ import annotations

from core.commands import FORCE
from stack.prod.libs import gates, host, tls

ABOUT = "Generate self-signed TLS certificate"
ARGUMENTS = (FORCE,)
USAGE = "setup-tls [-f]"


def run(force: bool) -> None:
    gates.enforce(host.DOCKER_GATES)
    if tls.present() and not force:
        print("TLS cert already exists. Use -f to overwrite.")
        return
    if force:
        print("Overwriting TLS cert (--force)...")
    else:
        tls.require_whole()
    tls.generate()
