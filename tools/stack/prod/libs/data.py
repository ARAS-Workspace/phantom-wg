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

from collections.abc import Sequence
from pathlib import Path

from core import runner
from stack.prod.libs import paths

KEPT = ".gitkeep"
TARGET = "/wipe"


def _holds_files(directory: Path) -> bool:
    return directory.is_dir() and any(entry.name != KEPT for entry in directory.iterdir())


def holding_files() -> list[Path]:
    return [runner.ROOT / name for name in paths.BOUND_DIRS if _holds_files(runner.ROOT / name)]


def wipe(directories: Sequence[Path], image: str) -> None:
    """Empties directories from one one-off container: the stack leaves files of root in them."""
    mounts = []
    for index, directory in enumerate(directories):
        mounts += ["--mount", f"type=bind,src={directory},dst={TARGET}/{index}"]
    runner.stream([
        "docker", "run", "--rm", "--pull", "never", "--network", "none",
        "--cap-drop", "ALL", "--cap-add", "DAC_OVERRIDE", *mounts,
        image,
        "find", TARGET, "-mindepth", "2", "-maxdepth", "2", "!", "-name", KEPT, "-exec", "rm", "-rf", "{}", "+",
    ])
