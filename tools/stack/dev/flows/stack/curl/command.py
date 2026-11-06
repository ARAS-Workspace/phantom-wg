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

curl: a request to the daemon through the gateway.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request

from core.commands import argument
from core.runner import ToolError

ABOUT = "Query via gateway (default: /api/core/hello)"
ARGUMENTS = (argument("path", nargs="?", default="/api/core/hello"),)
USAGE = "curl [path]"
GATEWAY = "http://127.0.0.1:9080"


def run(path: str) -> None:
    try:
        with urllib.request.urlopen(GATEWAY + path, timeout=10) as response:
            body = response.read()
    except urllib.error.HTTPError as error:
        body = error.read()
    except OSError as error:
        raise ToolError(f"The gateway does not answer: {error}") from error
    print(json.dumps(json.loads(body), indent=4))
