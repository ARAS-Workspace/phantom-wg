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

The address pool of a host: setup creates it once, in wallet.db.
"""

from __future__ import annotations

from core import runner
from stack.prod.libs import compose, identity, images, paths

CHECK = "phantom_daemon.base.wallet.subnet_check"
BOOTSTRAP = "phantom_daemon.base.wallet.bootstrap"
CODE = "/app/phantom_daemon"
DB_MOUNT = "/db"


def _code() -> str:
    return f"{runner.ROOT / 'phantom_daemon'}:{CODE}:ro"


def check(subnet: str) -> str:
    """The subnet as the daemon accepts it. The daemon says what is wrong with it."""
    image = images.ensure(compose.DAEMON)
    return runner.capture(["docker", "run", "--rm", "-v", _code(), image, "python", "-m", CHECK, subnet])


def present() -> bool:
    return paths.wallet().is_file()


def create(subnet: str) -> None:
    """The pool, from the code of this host. db/ belongs to root: the container writes as root."""
    compose.require_down()
    directory = paths.wallet().parent
    identity.make_dir(directory)
    image = images.ensure(compose.DAEMON)

    print("Creating the address pool...")
    runner.stream([
        "docker", "run", "--rm", "--network", "none",
        "-v", _code(),
        "--mount", f"type=bind,src={directory},dst={DB_MOUNT}",
        image,
        "python", "-m", BOOTSTRAP, DB_MOUNT, *([subnet] if subnet else []),
    ])
