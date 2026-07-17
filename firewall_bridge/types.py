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

Native exception hierarchy for firewall_bridge

Rust FFI error codes (negative) → kernel operation exceptions.
Python-side errors (DB, state) → Python exceptions.
"""


class BridgeError(Exception):
    """Base exception for all firewall bridge errors."""

    def __init__(self, message: str = ""):
        self.message = message
        super().__init__(message)


# ---- Rust FFI errors (kernel operations) ----

class NftablesError(BridgeError):
    """nftables operation failed."""


class NetlinkError(BridgeError):
    """Netlink routing operation failed."""


class InvalidParamError(BridgeError):
    """Invalid parameter passed to FFI."""


class IoError(BridgeError):
    """I/O error (file, proc, sysctl)."""


class PermissionDeniedError(BridgeError):
    """Permission denied — need CAP_NET_ADMIN."""


class NotInitializedError(BridgeError):
    """Kernel context not initialized — nft_init has not succeeded."""


# ---- Python-side errors (DB, state, groups) ----

class GroupNotFoundError(BridgeError):
    """Rule group not found."""


class RuleNotFoundError(BridgeError):
    """Firewall or routing rule not found."""


class AlreadyStartedError(BridgeError):
    """Bridge already started."""


class NotStartedError(BridgeError):
    """Bridge not started."""


class PresetValidationError(BridgeError):
    """Preset schema validation failed."""

    def __init__(self, field: str, reason: str, value: object = None):
        self.field = field
        self.reason = reason
        self.value = value
        msg = f"{field}: {reason}"
        if value is not None:
            msg += f" (got {value!r})"
        super().__init__(msg)


# FFI error code → exception class mapping (Rust kernel ops only)
_ERROR_MAP: dict[int, type[BridgeError]] = {
    -3: NftablesError,
    -4: NetlinkError,
    -5: InvalidParamError,
    -6: IoError,
    -7: PermissionDeniedError,
    -8: NotInitializedError,
}


def check_result(rc: int, detail: str = "") -> None:
    """Raise specific exception if rc is negative (Rust FFI error)."""
    if rc >= 0:
        return
    if not detail:
        from ._ffi import get_last_error
        detail = get_last_error()
    exc_cls = _ERROR_MAP.get(rc, BridgeError)
    msg = detail if detail else f"FFI error code: {rc}"
    raise exc_cls(msg)
