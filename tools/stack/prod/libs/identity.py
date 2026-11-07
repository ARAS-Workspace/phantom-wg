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

Who the files of an installation belong to.
"""

from __future__ import annotations

import os
from pathlib import Path


def operator() -> tuple[int, int]:
    """The owner of what the tool writes: under sudo, who ran sudo."""
    if os.geteuid() == 0 and "SUDO_UID" in os.environ:
        return int(os.environ["SUDO_UID"]), int(os.environ["SUDO_GID"])
    return os.getuid(), os.getgid()


def as_operator() -> list[str]:
    """Flags of a one-off container whose files belong to the operator."""
    uid, gid = operator()
    return ["--user", f"{uid}:{gid}"]


def own(path: Path) -> None:
    os.chown(path, *operator())


def make_dir(path: Path) -> None:
    created = [directory for directory in (path, *path.parents) if not directory.exists()]
    path.mkdir(parents=True, exist_ok=True)
    for directory in created:
        own(directory)
