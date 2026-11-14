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

The images of a release zip: images/ holds the tars, VERSION and SHA256SUMS.
"""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

from core import runner
from core.runner import ToolError

DIRECTORY = "images"
PINS = "tools/compose/registry.yml"
CHUNK = 1 << 20


def _path(name: str) -> Path:
    return runner.ROOT / DIRECTORY / name


def version() -> str:
    path = _path("VERSION")
    return path.read_text(encoding="utf-8").strip() if path.is_file() else ""


def _pinned() -> str:
    text = (runner.ROOT / PINS).read_text(encoding="utf-8")
    return ", ".join(sorted(set(re.findall(r"^    image: .*:([^:@]*)@sha256:", text, re.MULTILINE))))


def _listed() -> dict[str, str]:
    """The tars of SHA256SUMS: only these belong to the archive."""
    lines = _path("SHA256SUMS").read_text(encoding="utf-8").splitlines()
    return {name.lstrip("*"): digest for digest, name in (line.split(maxsplit=1) for line in lines if line.strip())}


def _digest(path: Path) -> str:
    found = hashlib.sha256()
    with path.open("rb") as tar:
        for chunk in iter(lambda: tar.read(CHUNK), b""):
            found.update(chunk)
    return found.hexdigest()


def check() -> None:
    if not _path("VERSION").is_file() or not _path("SHA256SUMS").is_file():
        raise ToolError(f"{DIRECTORY}/ holds no image archive.")
    if version() != _pinned():
        raise ToolError(f"{DIRECTORY}/ holds {version()}, this package pins {_pinned()}.")

    listed = _listed()
    if not listed:
        raise ToolError(f"{DIRECTORY}/ does not match SHA256SUMS.")
    for name, digest in listed.items():
        path = _path(name)
        if not path.is_file() or _digest(path) != digest:
            raise ToolError(f"{DIRECTORY}/ does not match SHA256SUMS: {name}")


def load() -> None:
    check()
    print("Loading images...")
    for name in _listed():
        runner.capture(["docker", "load", "-q", "-i", str(_path(name))])
    print("Images loaded.")
