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

The WireGuard keypair of the server.
"""

from __future__ import annotations

import os
from pathlib import Path

from core import runner
from core.runner import ToolError
from stack.prod.libs import compose, identity, images, paths

KEY_LENGTH = 64
GENERATE = """
from wireguard_go_bridge.keys import generate_private_key, derive_public_key
priv = generate_private_key()
pub = derive_public_key(priv)
print(priv)
print(pub)
"""
DERIVE = """
from pathlib import Path
from wireguard_go_bridge.keys import derive_public_key
print(derive_public_key(Path("/tmp/wg_private_key").read_text().strip()))
"""


def _paths() -> tuple[Path, Path]:
    return paths.secrets() / "wg_private_key", paths.secrets() / "wg_public_key"


def present() -> bool:
    return all(paths.filled(path) for path in _paths())


def _checked(key: str) -> str:
    if len(key) != KEY_LENGTH:
        raise ToolError("Key generation failed: unexpected length.")
    return key


def _write_private(path: Path, text: str) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as out:
        out.write(text)
    path.chmod(0o600)
    identity.own(path)


def _report(public_key: str) -> None:
    print(f"WG keys written to {paths.SECRETS_DIR}/")
    print("Public key:")
    print(f"  {public_key}")


def generate() -> None:
    compose.require_down()
    image = images.ensure(compose.DAEMON)

    print("Generating WireGuard keypair...")
    lines = runner.capture(["docker", "run", "--rm", image, "python", "-c", GENERATE]).splitlines()
    if len(lines) < 2:
        raise ToolError("Key generation failed: empty output.")
    private_key, public_key = _checked(lines[0]), _checked(lines[1])

    private_path, public_path = _paths()
    identity.make_dir(private_path.parent)
    _write_private(private_path, private_key)
    _write_private(public_path, public_key)
    _report(public_key)


def _restore_public(private_path: Path, public_path: Path) -> None:
    compose.require_down()
    image = images.ensure(compose.DAEMON)

    print("Deriving the public key from the private key...")
    public_key = _checked(runner.capture([
        "docker", "run", "--rm", *identity.as_operator(),
        "--mount", f"type=bind,src={private_path},dst=/tmp/wg_private_key,readonly",
        image, "python", "-c", DERIVE,
    ]))
    _write_private(public_path, public_key)
    _report(public_key)


def provide() -> None:
    """What setup does: a private key that survived stays, a lost one gives a new pair."""
    private_path, public_path = _paths()
    if paths.filled(private_path):
        _restore_public(private_path, public_path)
    else:
        generate()
