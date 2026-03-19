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

Argon2id password hashing via libsodium.
"""

from __future__ import annotations

import nacl.pwhash


def hash_password(password: str) -> str:
    """Hash password using Argon2id (libsodium MODERATE defaults)."""
    hashed = nacl.pwhash.argon2id.str(password.encode("utf-8"))
    return hashed.decode("ascii")


# noinspection PyUnresolvedReferences
def verify_password(password: str, stored_hash: str) -> bool:
    """Verify password against stored Argon2id hash. Constant-time."""
    try:
        return nacl.pwhash.verify(stored_hash.encode("ascii"), password.encode("utf-8"))
    except nacl.exceptions.InvalidkeyError:
        return False
