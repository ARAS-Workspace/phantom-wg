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

The E2E runners, on the host through compose-bridge.
"""

from __future__ import annotations

import os
from collections.abc import Sequence
from pathlib import Path

from core import runner
from core.runner import ToolError
from stack.dev.libs import compose

BRIDGE_DIR = "lib/compose_bridge"


def _library() -> Path:
    directory = runner.ROOT / BRIDGE_DIR
    found = sorted([*directory.glob("*.dylib"), *directory.glob("*.so")])
    if not found:
        raise ToolError("compose-bridge not found. Run: ./tools/dev.sh fetch-compose-bridge")
    return found[0]


def run(script: str, args: Sequence[str]) -> None:
    compose.require_down()
    library = _library()
    search_path = f"{runner.ROOT / 'lib'}:{os.environ.get('PYTHONPATH', '')}"
    environment = {"COMPOSE_BRIDGE_LIB_PATH": str(library), "PYTHONPATH": search_path}
    runner.stream(["python3", script, *args], env=environment)
