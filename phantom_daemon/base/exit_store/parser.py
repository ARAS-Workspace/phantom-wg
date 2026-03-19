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

WireGuard .conf parser — standard INI-style config to structured data.
"""

from __future__ import annotations

import base64
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class ParsedWireGuardConfig:
    """Parsed WireGuard configuration file."""

    private_key_hex: str
    address: str
    public_key_hex: str
    preshared_key_hex: str
    endpoint: str
    allowed_ips: str
    keepalive: int


def _base64_to_hex(b64_key: str) -> str:
    """Decode a WireGuard base64 key to hex string.

    Raises ValueError if key is not exactly 32 bytes after decoding.
    """
    raw = base64.b64decode(b64_key)
    if len(raw) != 32:
        raise ValueError(
            f"Key must be 32 bytes, got {len(raw)}: {b64_key}"
        )
    return raw.hex()


def parse_wireguard_config(raw_config: str) -> ParsedWireGuardConfig:
    """Parse a standard WireGuard .conf into structured data.

    Expected format:
        [Interface]
        PrivateKey = <base64>
        Address = <cidr>

        [Peer]
        PublicKey = <base64>
        PresharedKey = <base64>     # optional
        Endpoint = <host:port>
        AllowedIPs = <cidr>, ...
        PersistentKeepalive = <int> # optional, default 5

    Raises ValueError on missing required fields or invalid keys.
    """
    section = ""
    iface: dict[str, str] = {}
    peer: dict[str, str] = {}

    for raw_line in raw_config.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        if line.startswith("["):
            section = line.strip("[]").lower()
            continue

        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip().lower()
        value = value.strip()

        if section == "interface":
            iface[key] = value
        elif section == "peer":
            if key == "allowedips" and key in peer:
                peer[key] = f"{peer[key]}, {value}"
            else:
                peer[key] = value

    # Validate required fields
    if "privatekey" not in iface:
        raise ValueError("Missing [Interface] PrivateKey")
    if "address" not in iface:
        raise ValueError("Missing [Interface] Address")
    if "publickey" not in peer:
        raise ValueError("Missing [Peer] PublicKey")
    if "endpoint" not in peer:
        raise ValueError("Missing [Peer] Endpoint")

    private_key_hex = _base64_to_hex(iface["privatekey"])
    public_key_hex = _base64_to_hex(peer["publickey"])

    preshared_key_hex = ""
    if "presharedkey" in peer:
        preshared_key_hex = _base64_to_hex(peer["presharedkey"])

    allowed_ips = peer.get("allowedips", "0.0.0.0/0, ::/0")
    keepalive = int(peer.get("persistentkeepalive", "5"))

    return ParsedWireGuardConfig(
        private_key_hex=private_key_hex,
        address=iface["address"],
        public_key_hex=public_key_hex,
        preshared_key_hex=preshared_key_hex,
        endpoint=peer["endpoint"],
        allowed_ips=allowed_ips,
        keepalive=keepalive,
    )
