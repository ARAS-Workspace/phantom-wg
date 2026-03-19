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

Client .conf file builder — pure function, no framework dependency.
"""

from __future__ import annotations

from wireguard_go_bridge.keys import hex_to_base64


def build_client_config(
    version: str,
    client_private_key_hex: str,
    client_ipv4: str,
    client_ipv6: str,
    server_public_key_hex: str,
    preshared_key_hex: str,
    dns_v4: dict,
    dns_v6: dict,
    endpoint: str,
    keepalive: int,
    mtu: int,
) -> str:
    """Build a WireGuard .conf file for a client.

    version: "v4" | "v6" | "hybrid"
    Keys are hex-encoded, converted to base64 for the config.
    Returns a complete .conf string with trailing newline.
    """
    private_key_b64 = hex_to_base64(client_private_key_hex)
    public_key_b64 = hex_to_base64(server_public_key_hex)
    preshared_key_b64 = hex_to_base64(preshared_key_hex)

    # Address
    if version == "v4":
        address = f"{client_ipv4}/32"
    elif version == "v6":
        address = f"{client_ipv6}/128"
    else:
        address = f"{client_ipv4}/32, {client_ipv6}/128"

    # DNS
    if version == "v4":
        dns = f"{dns_v4['primary']}, {dns_v4['secondary']}"
    elif version == "v6":
        dns = f"{dns_v6['primary']}, {dns_v6['secondary']}"
    else:
        dns = (
            f"{dns_v4['primary']}, {dns_v4['secondary']}, "
            f"{dns_v6['primary']}, {dns_v6['secondary']}"
        )

    # AllowedIPs
    if version == "v4":
        allowed_ips = "0.0.0.0/0"
    elif version == "v6":
        allowed_ips = "::/0"
    else:
        allowed_ips = "0.0.0.0/0, ::/0"

    lines = [
        "[Interface]",
        f"PrivateKey = {private_key_b64}",
        f"Address = {address}",
        f"DNS = {dns}",
        f"MTU = {mtu}",
        "",
        "[Peer]",
        f"PublicKey = {public_key_b64}",
        f"PresharedKey = {preshared_key_b64}",
        f"AllowedIPs = {allowed_ips}",
        f"Endpoint = {endpoint}",
        f"PersistentKeepalive = {keepalive}",
        "",
    ]
    return "\n".join(lines)
