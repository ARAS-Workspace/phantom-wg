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

Ed25519 key loading for JWT signing.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from nacl.signing import SigningKey, VerifyKey

from auth_service.errors import AuthSecretsError

_HEX64_RE = re.compile(r"^[0-9a-fA-F]{64}$")


@dataclass(frozen=True, slots=True)
class AuthSigningKeys:
    """Immutable container for Ed25519 key pair (hex-encoded)."""

    signing_key_hex: str
    verify_key_hex: str


def _read_key(path: Path, name: str) -> str:
    """Read and validate a single 64-char hex key file."""
    if not path.is_file():
        raise AuthSecretsError(f"Secret file not found: {path}")
    raw = path.read_text().strip()
    if not _HEX64_RE.match(raw):
        raise AuthSecretsError(
            f"Invalid {name}: expected 64 hex characters, got {len(raw)} chars"
        )
    return raw


def load_auth_keys(secrets_dir: str = "/run/secrets") -> AuthSigningKeys:
    """Load Ed25519 key pair from Docker secrets directory."""
    base = Path(secrets_dir)
    signing = _read_key(base / "auth_signing_key", "auth_signing_key")
    verify = _read_key(base / "auth_verify_key", "auth_verify_key")
    return AuthSigningKeys(signing_key_hex=signing, verify_key_hex=verify)


def build_signing_key(keys: AuthSigningKeys) -> SigningKey:
    """Build nacl SigningKey from hex seed."""
    return SigningKey(bytes.fromhex(keys.signing_key_hex))


def build_verify_key(keys: AuthSigningKeys) -> VerifyKey:
    """Build nacl VerifyKey from hex."""
    return VerifyKey(bytes.fromhex(keys.verify_key_hex))
