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

The images of the development services.
"""

from __future__ import annotations

import os

from core import runner

IMAGES_FILE = "tools/compose/dev.yml"


def _compose() -> list[str]:
    """Compose on the image file: on the stack, config --images also lists depends_on."""
    return ["docker", "compose", "-f", str(runner.ROOT / IMAGES_FILE)]


def ensure(service: str) -> str:
    """The image of a service, built here when it is missing."""
    reference = runner.capture([*_compose(), "config", "--images", service])
    if not runner.probe(["docker", "image", "inspect", reference]).ok:
        print(f"Building {reference}...")
        runner.stream([*_compose(), "build", service])
    return reference


def as_operator() -> list[str]:
    """Flags of a one-off container whose files belong to whoever runs the tool."""
    return ["--user", f"{os.getuid()}:{os.getgid()}"]
