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

images: the source of this host, its images and how they arrive.
"""

from __future__ import annotations

from core.commands import argument
from core.runner import ToolError
from stack.prod.libs import images

ABOUT = "Show or change the image source"
ARGUMENTS = (
    argument("action", nargs="?", default="status", choices=("status", "use", "sync")),
    argument("source", nargs="?"),
)
USAGE = "images [status|use {registry|build|archive}|sync]"


def run(action: str, source: str | None) -> None:
    valid = source in images.SOURCES if action == "use" else source is None
    if not valid:
        raise ToolError(f"Usage: ./tools/prod.sh {USAGE}")

    if action == "use":
        images.select(source)
    elif action == "sync":
        images.sync()
    else:
        images.status()
