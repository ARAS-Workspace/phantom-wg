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

WireGuard .conf renderer — a stored exit back to the text the parser reads.
"""

from __future__ import annotations

import base64
from collections.abc import Mapping


def _hex_to_base64(hex_key: str) -> str:
    """Encode a hex key as WireGuard base64 — the inverse of the parser's decode."""
    return base64.b64encode(bytes.fromhex(hex_key)).decode("ascii")


def render_wireguard_config(exit_data: Mapping[str, str | int]) -> str:
    """Render a stored exit as a WireGuard .conf, in the format the parser reads.

    Contract: parse_wireguard_config on the result returns the stored values
    of all seven fields. AllowedIPs and PersistentKeepalive are always
    written, as the parser fills in defaults when they are missing (a stored
    keepalive of 0 would come back as 5). PresharedKey is written only when
    one is stored. Returns the text with a trailing newline.
    """
    lines = [
        "[Interface]",
        f"PrivateKey = {_hex_to_base64(str(exit_data['private_key_hex']))}",
        f"Address = {exit_data['address']}",
        "",
        "[Peer]",
        f"PublicKey = {_hex_to_base64(str(exit_data['public_key_hex']))}",
    ]
    if exit_data["preshared_key_hex"]:
        lines.append(
            f"PresharedKey = {_hex_to_base64(str(exit_data['preshared_key_hex']))}"
        )
    lines += [
        f"Endpoint = {exit_data['endpoint']}",
        f"AllowedIPs = {exit_data['allowed_ips']}",
        f"PersistentKeepalive = {exit_data['keepalive']}",
    ]
    return "\n".join(lines) + "\n"
