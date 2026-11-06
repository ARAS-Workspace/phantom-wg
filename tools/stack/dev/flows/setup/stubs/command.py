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

stubs: the type stubs of the vendor packages.
"""

from __future__ import annotations

import shutil
from pathlib import Path

from core import runner
from stack.dev.libs import compose, images

ABOUT = "Generate .pyi vendor stubs"
OUT_DIR = "typings"
VENDOR_DIR = "/opt/phantom/vendor"
GENERATOR = Path(__file__).resolve().with_name("gen_stubs.py")


def run() -> None:
    image = images.ensure(compose.DAEMON)

    out = runner.ROOT / OUT_DIR
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir()

    print("Generating type stubs from vendor packages...")
    runner.stream([
        "docker", "run", "--rm", *images.as_operator(),
        "-v", f"{GENERATOR}:/tmp/gen_stubs.py:ro",
        "-v", f"{out}:/out",
        image,
        "python", "/tmp/gen_stubs.py", VENDOR_DIR, "/out",
    ])
    print(f"Stubs written to {OUT_DIR}/")
