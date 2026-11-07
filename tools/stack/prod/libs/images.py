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

The image source of this host and the images it gives.
"""

from __future__ import annotations

from core import runner
from core.runner import ToolError

SOURCES = ("registry", "build", "archive")
DEFAULT_SOURCE = "registry"
VARIABLE = "PHANTOM_IMAGE_SOURCE"


def _settings_file() -> str:
    """.env, else .env.example, as Compose takes them."""
    return ".env" if (runner.ROOT / ".env").is_file() else ".env.example"


def source() -> str:
    """The source Compose reads, so the tool and the stack never differ."""
    settings = runner.capture([
        "docker", "compose", "--project-directory", ".", "--env-file", _settings_file(),
        "-f", f"tools/compose/{DEFAULT_SOURCE}.yml", "config", "--environment",
    ])
    values = dict(line.split("=", 1) for line in settings.splitlines() if "=" in line)
    value = values.get(VARIABLE) or DEFAULT_SOURCE
    if value not in SOURCES:
        raise ToolError(f"Unknown image source: {value}\nUse one of: {', '.join(SOURCES)}")
    return value


def _compose(selected: str) -> list[str]:
    """Compose on the image file: on the stack, config --images also lists depends_on."""
    return ["docker", "compose", "-f", f"tools/compose/{selected}.yml"]


def ensure(service: str) -> str:
    """The image of a service, from the source of this host when it is missing."""
    selected = source()
    reference = runner.capture([*_compose(selected), "config", "--images", service])
    if runner.probe(["docker", "image", "inspect", reference]).ok:
        return reference

    if selected == "archive":
        raise ToolError(f"{reference} is not loaded.")
    action = "pull" if selected == "registry" else "build"
    print(f"Getting {reference}...")
    runner.stream([*_compose(selected), action, service])
    return reference
