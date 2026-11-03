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

Curve25519 key generation via Go FFI. A key the bridge refuses raises
InvalidArgumentError, a ValueError, with code -10. Any other failure
raises RuntimeError from the generate functions and ValueError from
derive_public_key and hex_to_base64. The exception carries the bridge's
message when the bridge recorded one.
"""

from ._ffi import get_lib, _read_and_free, last_error
from .types import InvalidArgumentError, _ERROR_MAP


def _failure(lib, what: str, exc_type: type[Exception]) -> Exception:
    """The exception for a failed call: what, then the message the bridge
    recorded for this thread's call."""
    code, message = last_error(lib)
    text = f"{what}: {message}" if message else what
    if _ERROR_MAP.get(code) is InvalidArgumentError:
        return InvalidArgumentError(text, code)
    return exc_type(text)


def generate_private_key() -> str:
    """Generate a new Curve25519 private key. Returns hex string."""
    lib = get_lib()
    result = _read_and_free(lib.GeneratePrivateKey())
    if not result:
        raise _failure(lib, "Failed to generate private key", RuntimeError)
    return result


def derive_public_key(private_key_hex: str) -> str:
    """Derive public key from private key. Returns hex string."""
    lib = get_lib()
    result = _read_and_free(lib.DerivePublicKey(private_key_hex.encode("utf-8")))
    if not result:
        raise _failure(lib, "Failed to derive public key", ValueError)
    return result


def generate_preshared_key() -> str:
    """Generate a random 32-byte preshared key. Returns hex string."""
    lib = get_lib()
    result = _read_and_free(lib.GeneratePresharedKey())
    if not result:
        raise _failure(lib, "Failed to generate preshared key", RuntimeError)
    return result


def hex_to_base64(hex_str: str) -> str:
    """Convert hex-encoded key to base64 (WireGuard config format)."""
    lib = get_lib()
    result = _read_and_free(lib.HexToBase64(hex_str.encode("utf-8")))
    if not result:
        raise _failure(lib, "Failed to convert hex to base64", ValueError)
    return result
