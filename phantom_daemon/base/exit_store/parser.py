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
import binascii
import ipaddress
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class ParsedWireGuardConfig:
    """A WireGuard configuration that is guaranteed well-formed.

    Every field is validated by parse_wireguard_config before this exists:
    keys decode to 32 bytes, addresses and AllowedIPs are valid CIDRs, the
    endpoint is host:port with an in-range port, and keepalive is 0-65535.
    Consumers may hand these values to the bridges without re-checking.
    """

    private_key_hex: str
    address: str
    public_key_hex: str
    preshared_key_hex: str
    endpoint: str
    allowed_ips: str
    keepalive: int


def _base64_to_hex(b64_key: str, field: str = "Key") -> str:
    """Decode a WireGuard base64 key to hex string.

    The key itself never appears in the error: this message travels to the
    HTTP response and the audit log, and a length is enough to diagnose.

    Raises ValueError if not valid base64 or not exactly 32 bytes.
    """
    try:
        raw = base64.b64decode(b64_key, validate=True)
    except (binascii.Error, ValueError):
        raise ValueError(f"{field} is not valid base64") from None
    if len(raw) != 32:
        raise ValueError(f"{field} must be 32 bytes, got {len(raw)}")
    return raw.hex()


def _split_csv(value: str) -> list[str]:
    """Split a comma-separated field into non-empty stripped parts."""
    return [p.strip() for p in value.split(",") if p.strip()]


def _validate_address(address: str) -> str:
    """Validate [Interface] Address — one or more host CIDRs."""
    parts = _split_csv(address)
    if not parts:
        raise ValueError("[Interface] Address is empty")
    for part in parts:
        try:
            ipaddress.ip_interface(part)
        except ValueError:
            raise ValueError(
                f"[Interface] Address is not a valid CIDR: {part}"
            ) from None
    return ", ".join(parts)


def _validate_allowed_ips(allowed_ips: str) -> str:
    """Validate [Peer] AllowedIPs — one or more network CIDRs.

    A silent miss here is expensive: the daemon derives has_v4/has_v6 from
    this string to decide which multihop presets to apply, so an unparsable
    entry would mean no routing at all.
    """
    parts = _split_csv(allowed_ips)
    if not parts:
        raise ValueError("[Peer] AllowedIPs is empty")
    for part in parts:
        try:
            ipaddress.ip_network(part, strict=False)
        except ValueError:
            raise ValueError(
                f"[Peer] AllowedIPs is not a valid CIDR: {part}"
            ) from None
    return ", ".join(parts)


def _looks_like_ipv4(host: str) -> bool:
    """Four dot-separated all-numeric labels — a hostname would not be."""
    labels = host.split(".")
    return len(labels) == 4 and all(label.isdigit() for label in labels)


def _validate_endpoint(endpoint: str) -> str:
    """Validate [Peer] Endpoint — host:port.

    No address family is inferred. The host may be a hostname, whose family
    is decided by DNS at resolution time and may be A, AAAA, or both, so it
    is not knowable here and must not be guessed. Only literal forms are
    checked: an IPv4 literal must parse, and an IPv6 literal must be
    bracketed — `2001:db8::1:51820` is genuinely ambiguous (it is itself a
    valid IPv6 address), which is why WireGuard requires the brackets.
    """
    if endpoint.startswith("["):
        host, sep, port_str = endpoint.partition("]:")
        if not sep:
            raise ValueError(f"[Peer] Endpoint must be [ipv6]:port: {endpoint}")
        try:
            ipaddress.IPv6Address(host[1:])
        except ValueError:
            raise ValueError(
                f"[Peer] Endpoint IPv6 host is not valid: {host}]"
            ) from None
    else:
        host, sep, port_str = endpoint.partition(":")
        if not sep or not host:
            raise ValueError(f"[Peer] Endpoint must be host:port: {endpoint}")
        if ":" in port_str:
            raise ValueError(
                f"[Peer] Endpoint has multiple colons — bracket IPv6 "
                f"literals as [address]:port: {endpoint}"
            )
        if _looks_like_ipv4(host):
            try:
                ipaddress.IPv4Address(host)
            except ValueError:
                raise ValueError(
                    f"[Peer] Endpoint IPv4 host is not valid: {host}"
                ) from None

    try:
        port = int(port_str)
    except ValueError:
        raise ValueError(
            f"[Peer] Endpoint port is not a number: {port_str}"
        ) from None
    if not 1 <= port <= 65535:
        raise ValueError(f"[Peer] Endpoint port out of range (1-65535): {port}")
    return endpoint


def _validate_keepalive(value: str) -> int:
    """Validate [Peer] PersistentKeepalive — seconds, 0 disables."""
    try:
        seconds = int(value)
    except ValueError:
        raise ValueError(
            f"[Peer] PersistentKeepalive is not a number: {value}"
        ) from None
    if not 0 <= seconds <= 65535:
        raise ValueError(
            f"[Peer] PersistentKeepalive out of range (0-65535): {seconds}"
        )
    return seconds


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

    private_key_hex = _base64_to_hex(iface["privatekey"], "[Interface] PrivateKey")
    public_key_hex = _base64_to_hex(peer["publickey"], "[Peer] PublicKey")

    preshared_key_hex = ""
    if "presharedkey" in peer:
        preshared_key_hex = _base64_to_hex(peer["presharedkey"], "[Peer] PresharedKey")

    return ParsedWireGuardConfig(
        private_key_hex=private_key_hex,
        address=_validate_address(iface["address"]),
        public_key_hex=public_key_hex,
        preshared_key_hex=preshared_key_hex,
        endpoint=_validate_endpoint(peer["endpoint"]),
        allowed_ips=_validate_allowed_ips(peer.get("allowedips", "0.0.0.0/0, ::/0")),
        keepalive=_validate_keepalive(peer.get("persistentkeepalive", "5")),
    )
