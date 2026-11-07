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

The version of the code and the one this host applied.
"""

from __future__ import annotations

import re

from core import runner
from core.runner import ToolError
from stack.prod.libs import identity

APPLIED_FILE = "container-data/.applied-version"
CODE_FILE = "phantom_daemon/__init__.py"


def code() -> str:
    found = re.search(r'^__version__ = "(.+)"$', (runner.ROOT / CODE_FILE).read_text(encoding="utf-8"), re.MULTILINE)
    if not found:
        raise ToolError(f"{CODE_FILE} holds no version.")
    return found[1]


def record() -> None:
    path = runner.ROOT / APPLIED_FILE
    identity.make_dir(path.parent)
    path.write_text(f"{code()}\n", encoding="utf-8")
    identity.own(path)


def forget() -> None:
    (runner.ROOT / APPLIED_FILE).unlink(missing_ok=True)
