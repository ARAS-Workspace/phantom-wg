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

The wallet of the dev stack: setup creates it, the daemon opens it.
"""

from __future__ import annotations

from pathlib import Path

from core import runner
from stack.dev.libs import compose, images, paths

BOOTSTRAP = "phantom_daemon.base.wallet.bootstrap"
DB_MOUNT = "/db"


def _path() -> Path:
    return runner.ROOT / paths.DB_DIR / "wallet.db"


def present() -> bool:
    return _path().is_file()


def create() -> None:
    compose.require_down()
    image = images.ensure(compose.DAEMON)
    directory = _path().parent
    directory.mkdir(parents=True, exist_ok=True)

    print("Creating the wallet...")
    runner.stream([
        "docker", "run", "--rm", "--network", "none",
        "-v", f"{runner.ROOT / 'phantom_daemon'}:/app/phantom_daemon:ro",
        "--mount", f"type=bind,src={directory},dst={DB_MOUNT}",
        image,
        "python", "-m", BOOTSTRAP, DB_MOUNT,
    ])
