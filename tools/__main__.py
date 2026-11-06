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

Starts the toolchain: tools/prod.sh and tools/dev.sh land here.

This file, core/__init__.py and core/floor.py stay plain, so a Python under the
floor reads them and reports itself before any other module loads.
"""

import importlib
import sys

from core.floor import PYTHON

PROFILES = ("prod", "dev")


def main():
    if sys.version_info < PYTHON:
        floor = ".".join(map(str, PYTHON))
        found = ".".join(map(str, sys.version_info[:2]))
        sys.exit(f"Python {floor} or newer is required, this is {found}.")

    if sys.argv[1:2] not in [[name] for name in PROFILES]:
        sys.exit("Start the toolchain with prod.sh or dev.sh.")

    app = importlib.import_module("core.app")
    stack = importlib.import_module(f"stack.{sys.argv[1]}.entry")
    app.run(stack.ENTRY, stack.FLOWS, sys.argv[2:])


main()
