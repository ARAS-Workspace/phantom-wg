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

The emptying of the directories of container-data.
"""

from __future__ import annotations

from pathlib import Path

from core import runner
from stack.dev.libs import compose, images, paths

KEPT = ".gitkeep"
TARGET = "/wipe"


def _holds_files(directory: Path) -> bool:
    return directory.is_dir() and any(entry.name != KEPT for entry in directory.iterdir())


def wipe(*directories: Path) -> None:
    """Empties directories from a one-off container: the stack leaves files of root in them."""
    targets = [directory for directory in directories if _holds_files(directory)]
    if not targets:
        return

    image = images.ensure(compose.DAEMON)
    mounts = []
    for index, directory in enumerate(targets):
        mounts += ["--mount", f"type=bind,src={directory},dst={TARGET}/{index}"]
    runner.stream([
        "docker", "run", "--rm", "--pull", "never", "--network", "none",
        "--cap-drop", "ALL", "--cap-add", "DAC_OVERRIDE", *mounts,
        image,
        "find", TARGET, "-mindepth", "2", "-maxdepth", "2", "!", "-name", KEPT, "-exec", "rm", "-rf", "{}", "+",
    ])


def wipe_bound() -> None:
    """Empties every directory the containers of development use."""
    wipe(*(runner.ROOT / name for name in paths.BOUND_DIRS))
