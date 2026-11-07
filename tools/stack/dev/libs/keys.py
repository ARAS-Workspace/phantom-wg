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

The WireGuard keypair of the development server.
"""

from __future__ import annotations

import os
from pathlib import Path

from core import runner
from core.runner import ToolError
from stack.dev.libs import compose, images, paths

KEY_LENGTH = 64
GENERATE = """
from wireguard_go_bridge.keys import generate_private_key, derive_public_key
priv = generate_private_key()
pub = derive_public_key(priv)
print(priv)
print(pub)
"""


def _paths() -> tuple[Path, Path]:
    return paths.secrets() / "wg_private_key", paths.secrets() / "wg_public_key"


def present() -> bool:
    return all(paths.filled(path) for path in _paths())


def parse(output: str) -> tuple[str, str]:
    """The private and the public key of what the container printed."""
    lines = output.splitlines()
    if len(lines) < 2 or not lines[0] or not lines[1]:
        raise ToolError("Key generation failed: empty output.")
    private_key, public_key = lines[0], lines[1]
    if len(private_key) != KEY_LENGTH or len(public_key) != KEY_LENGTH:
        raise ToolError("Key generation failed: unexpected length.")
    return private_key, public_key


def _write_private(path: Path, text: str) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as out:
        out.write(text)
    path.chmod(0o600)


def generate() -> None:
    compose.require_down()
    image = images.ensure(compose.DAEMON)

    print("Generating WireGuard keypair...")
    output = runner.capture(["docker", "run", "--rm", image, "python", "-c", GENERATE])
    private_key, public_key = parse(output)

    private_path, public_path = _paths()
    private_path.parent.mkdir(parents=True, exist_ok=True)
    _write_private(private_path, private_key)
    _write_private(public_path, public_key)

    print(f"WG keys written to {paths.SECRETS_DIR}/")
    print("Public key:")
    print(f"  {public_key}")
