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

One run of the toolchain, from the flows of a stack to the exit code.
"""

from __future__ import annotations

import sys
from collections.abc import Sequence

from core.commands import dispatch
from core.runner import ToolError

EXIT_INTERRUPTED = 130
EXIT_BROKEN_PIPE = 141


def run(entry: str, flows: str, argv: Sequence[str]) -> None:
    try:
        dispatch(entry, flows, argv)
    except ToolError as error:
        print(error, file=sys.stderr)
        sys.exit(error.code)
    except KeyboardInterrupt:
        sys.exit(EXIT_INTERRUPTED)
    except BrokenPipeError:
        sys.exit(EXIT_BROKEN_PIPE)
