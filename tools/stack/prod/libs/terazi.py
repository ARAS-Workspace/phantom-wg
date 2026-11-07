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

The subnet setup was asked for, until the first up uses it.
"""

from __future__ import annotations

from core import runner
from stack.prod.libs import compose, identity, images

SUBNET_FILE = ".terazi-subnet"
CHECK = "phantom_daemon.base.wallet.subnet_check"


def check(subnet: str) -> str:
    """The subnet as the daemon accepts it. The daemon says what is wrong with it."""
    image = images.ensure(compose.DAEMON)
    return runner.capture([
        "docker", "run", "--rm",
        "-v", f"{runner.ROOT / 'phantom_daemon'}:/app/phantom_daemon:ro",
        image, "python", "-m", CHECK, subnet,
    ])


def remember(subnet: str) -> None:
    path = runner.ROOT / SUBNET_FILE
    path.write_text(f"{subnet}\n", encoding="utf-8")
    identity.own(path)


def pending() -> str:
    path = runner.ROOT / SUBNET_FILE
    return path.read_text(encoding="utf-8").strip() if path.is_file() else ""


def forget() -> None:
    (runner.ROOT / SUBNET_FILE).unlink(missing_ok=True)
