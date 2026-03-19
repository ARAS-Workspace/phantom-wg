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

Server key loading.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from phantom_daemon.base.errors import SecretsError

_HEX64_RE = re.compile(r"^[0-9a-fA-F]{64}$")


@dataclass(frozen=True, slots=True)
class ServerKeys:
    """Immutable container for WireGuard server key pair (hex-encoded)."""

    private_key_hex: str
    public_key_hex: str


def _read_key(path: Path, name: str) -> str:
    """Read and validate a single 64-char hex key file."""
    if not path.is_file():
        raise SecretsError(f"Secret file not found: {path}")
    raw = path.read_text().strip()
    if not _HEX64_RE.match(raw):
        raise SecretsError(
            f"Invalid {name}: expected 64 hex characters, got {len(raw)} chars"
        )
    return raw


def load_secrets(secrets_dir: str = "/run/secrets/") -> ServerKeys:
    """Load WireGuard server keys from Docker secrets directory."""
    base = Path(secrets_dir)
    private = _read_key(base / "wg_private_key", "wg_private_key")
    public = _read_key(base / "wg_public_key", "wg_public_key")
    return ServerKeys(private_key_hex=private, public_key_hex=public)
