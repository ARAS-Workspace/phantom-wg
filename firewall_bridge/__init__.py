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

firewall_bridge — ufw pattern firewall manager.
SQLite state persistence, YAML-driven presets, crash recovery.
Rust backend: pure nftables + netlink kernel operations.
"""

__version__ = "2.1.6"

from .types import (
    BridgeError,
    NftablesError,
    NetlinkError,
    InvalidParamError,
    IoError,
    PermissionDeniedError,
    GroupNotFoundError,
    RuleNotFoundError,
    AlreadyStartedError,
    NotStartedError,
    PresetValidationError,
    check_result,
)
from ._ffi import get_lib, get_version
from .bridge import FirewallBridge
from .models import Group, FirewallRule, RoutingRule
from .schema import validate_preset
from .presets import apply_preset, remove_preset, enable_preset, disable_preset

__all__ = [
    "FirewallBridge",
    "Group",
    "FirewallRule",
    "RoutingRule",
    "BridgeError",
    "NftablesError",
    "NetlinkError",
    "InvalidParamError",
    "IoError",
    "PermissionDeniedError",
    "GroupNotFoundError",
    "RuleNotFoundError",
    "AlreadyStartedError",
    "NotStartedError",
    "PresetValidationError",
    "check_result",
    "validate_preset",
    "get_lib",
    "get_version",
    "apply_preset",
    "remove_preset",
    "enable_preset",
    "disable_preset",
]
