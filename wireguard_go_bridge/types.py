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

Exception types for wireguard-go-bridge: one per error code of the bridge.
An exception carries the code and the message the bridge recorded for
the call that failed.
"""


class BridgeError(Exception):
    """Base exception for all bridge operations. code is the bridge's
    error code, 0 for an error the bridge did not report."""

    def __init__(self, message: str = "", code: int = 0) -> None:
        super().__init__(message)
        self.code = code


class DeviceCreateError(BridgeError):
    """WireGuard device creation failed."""


class TunCreateError(DeviceCreateError):
    """TUN device creation failed."""


class IpcError(BridgeError):
    """IPC set/get operation failed."""


class DeviceNotFoundError(BridgeError):
    """Device handle not found."""


class DeviceUpError(BridgeError):
    """Device activation (up) failed."""


class DeviceDownError(BridgeError):
    """Device deactivation (down) failed."""


class InvalidArgumentError(BridgeError, ValueError):
    """The bridge refused an argument, such as a key that is not hex."""


# Go error code → Python exception mapping
_ERROR_MAP = {
    -2: TunCreateError,
    -3: DeviceCreateError,
    -4: IpcError,
    -5: DeviceNotFoundError,
    -7: DeviceUpError,
    -8: DeviceDownError,
    -10: InvalidArgumentError,
    -99: BridgeError,
}


def check_result(code: int, message: str = "") -> None:
    """Raise the exception of a negative code, with message, the one the
    bridge recorded, when there is one."""
    if code >= 0:
        return
    exc_cls = _ERROR_MAP.get(code, BridgeError)
    raise exc_cls(message or f"FFI error code: {code}", code)
