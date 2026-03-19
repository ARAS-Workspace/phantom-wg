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

TOTP (RFC 6238) implementation using stdlib HMAC-SHA1.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
import struct
import time

_PERIOD = 30
_DIGITS = 6
_BACKUP_CODE_COUNT = 8
_BACKUP_CODE_LENGTH = 8


def generate_secret() -> str:
    """Generate a random base32-encoded TOTP secret (160-bit)."""
    return base64.b32encode(secrets.token_bytes(20)).decode("ascii")


def build_totp_uri(secret: str, username: str, issuer: str = "Phantom") -> str:
    """Build otpauth:// URI for authenticator app enrollment."""
    return (
        f"otpauth://totp/{issuer}:{username}"
        f"?secret={secret}&issuer={issuer}&algorithm=SHA1&digits={_DIGITS}&period={_PERIOD}"
    )


def verify_totp(secret: str, code: str, window: int = 1) -> bool:
    """Verify a 6-digit TOTP code with time window tolerance."""
    if len(code) != _DIGITS or not code.isdigit():
        return False
    key = base64.b32decode(secret)
    now = int(time.time()) // _PERIOD
    for offset in range(-window, window + 1):
        counter = struct.pack(">Q", now + offset)
        mac = hmac.new(key, counter, hashlib.sha1).digest()
        offset_byte = mac[-1] & 0x0F
        truncated = struct.unpack(">I", mac[offset_byte : offset_byte + 4])[0] & 0x7FFFFFFF
        expected = str(truncated % (10 ** _DIGITS)).zfill(_DIGITS)
        if hmac.compare_digest(code, expected):
            return True
    return False


def generate_backup_codes() -> list[str]:
    """Generate 8 random alphanumeric backup codes."""
    alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    codes = []
    for _ in range(_BACKUP_CODE_COUNT):
        code = "".join(secrets.choice(alphabet) for _ in range(_BACKUP_CODE_LENGTH))
        codes.append(code)
    return codes


def hash_backup_code(code: str) -> str:
    """SHA-256 hash of a backup code for secure storage."""
    return hashlib.sha256(code.encode("utf-8")).hexdigest()
