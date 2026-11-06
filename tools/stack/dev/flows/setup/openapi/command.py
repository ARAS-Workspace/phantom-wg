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

openapi: the schema of the daemon, read inside its container.
"""

from __future__ import annotations

from core import runner
from stack.dev.libs import compose

ABOUT = "Export OpenAPI schema (openapi.json)"
TARGET = "openapi.json"
EXPORT = """
import json
from phantom_daemon.main import create_app
app = create_app(lifespan_func=None)
print(json.dumps(app.openapi(), indent=2))
"""


def run() -> None:
    print("Exporting OpenAPI schema...")
    schema = compose.capture("exec", "-T", compose.DAEMON, "python", "-c", EXPORT)
    (runner.ROOT / TARGET).write_text(schema + "\n", encoding="utf-8")
    print(f"Written to {TARGET}")
