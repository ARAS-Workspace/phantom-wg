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

wireguard_go_bridge — Python FFI bindings for wireguard-go-bridge.
PersistentDevice with automatic IPC state persistence + key generation.
"""

__version__ = "2.1.3"

from .types import (
    BridgeError,
    TunCreateError,
    DeviceCreateError,
    IpcError,
    DeviceNotFoundError,
    DeviceUpError,
    DeviceDownError,
)
from ._ffi import get_lib, get_bridge_version
from .bridge import WireGuardBridge
from .keys import (
    generate_private_key,
    derive_public_key,
    generate_preshared_key,
    hex_to_base64,
)

__all__ = [
    "WireGuardBridge",
    "BridgeError",
    "TunCreateError",
    "DeviceCreateError",
    "IpcError",
    "DeviceNotFoundError",
    "DeviceUpError",
    "DeviceDownError",
    "get_lib",
    "get_bridge_version",
    "generate_private_key",
    "derive_public_key",
    "generate_preshared_key",
    "hex_to_base64",
]
