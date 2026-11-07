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

certbot: a Let's Encrypt certificate for this host.

The flow runs in helper/certbot.sh, beside the stack: nginx reads the new
certificate on its restart. A cron job runs the same command.
"""

from __future__ import annotations

from pathlib import Path

from core import runner
from core.commands import argument
from stack.prod.libs import gates, host

ABOUT = "Obtain Let's Encrypt TLS certificate"
ARGUMENTS = (argument("domain"),)
USAGE = "certbot <domain>"

SCRIPT = Path(__file__).resolve().parent / "helper" / "certbot.sh"


def run(domain: str) -> None:
    gates.enforce(host.DOCKER_GATES)
    runner.stream(["bash", str(SCRIPT), domain])
