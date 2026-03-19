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

IPC config builder and parser — pure functions, no FFI dependency.
"""

from __future__ import annotations

from dataclasses import dataclass, field


# ── UAPI Status Types ────────────────────────────────────────────


@dataclass
class PeerStatus:
    public_key: str = ""
    endpoint: str = ""
    allowed_ips: list[str] = field(default_factory=list)
    latest_handshake: int = 0
    rx_bytes: int = 0
    tx_bytes: int = 0
    keepalive: int = 0


@dataclass
class DeviceStatus:
    public_key: str = ""
    listen_port: int = 0
    fwmark: int = 0
    peers: list[PeerStatus] = field(default_factory=list)


# ── Config Builders ──────────────────────────────────────────────


def build_server_config(private_key_hex: str, listen_port: int) -> str:
    """Build server-section IPC config string."""
    return f"private_key={private_key_hex}\nlisten_port={listen_port}\n"


def build_peer_config(
    public_key_hex: str,
    preshared_key_hex: str,
    ipv4_address: str,
    ipv6_address: str,
    keepalive: int,
) -> str:
    """Build a single peer IPC config block."""
    return (
        f"public_key={public_key_hex}\n"
        f"preshared_key={preshared_key_hex}\n"
        f"allowed_ip={ipv4_address}/32\n"
        f"allowed_ip={ipv6_address}/128\n"
        f"persistent_keepalive_interval={keepalive}\n"
    )


def build_full_config(
    private_key_hex: str,
    listen_port: int,
    clients: list[dict],
    keepalive: int,
) -> str:
    """Build complete IPC config with server + replace_peers + all peers."""
    parts = [build_server_config(private_key_hex, listen_port), "replace_peers=true\n"]
    for c in clients:
        parts.append(
            build_peer_config(
                public_key_hex=c["public_key_hex"],
                preshared_key_hex=c["preshared_key_hex"],
                ipv4_address=c["ipv4_address"],
                ipv6_address=c["ipv6_address"],
                keepalive=keepalive,
            )
        )
    return "".join(parts)


def build_exit_config(
    private_key_hex: str,
    peer_public_key_hex: str,
    peer_preshared_key_hex: str,
    endpoint: str,
    allowed_ips: str,
    keepalive: int,
) -> str:
    """Build IPC config for exit tunnel (client mode, no listen_port).

    allowed_ips is comma-separated — each entry becomes an allowed_ip= line.
    """
    parts = [
        f"private_key={private_key_hex}\n",
        "replace_peers=true\n",
        f"public_key={peer_public_key_hex}\n",
    ]
    if peer_preshared_key_hex:
        parts.append(f"preshared_key={peer_preshared_key_hex}\n")
    parts.append(f"endpoint={endpoint}\n")
    for ip in allowed_ips.split(","):
        ip = ip.strip()
        if ip:
            parts.append(f"allowed_ip={ip}\n")
    parts.append(f"persistent_keepalive_interval={keepalive}\n")
    return "".join(parts)


def build_peer_remove_config(public_key_hex: str) -> str:
    """Build IPC config to remove a single peer."""
    return f"public_key={public_key_hex}\nremove=true\n"


def parse_ipc_peers(ipc_output: str) -> set[str]:
    """Extract peer public keys from IPC get output."""
    peers: set[str] = set()
    for line in ipc_output.splitlines():
        if line.startswith("public_key="):
            peers.add(line.split("=", 1)[1])
    return peers


def parse_device_status(ipc_dump: str) -> DeviceStatus:
    """Parse full UAPI dump into structured DeviceStatus.

    Interface fields: private_key → derive public key, listen_port, fwmark.
    Peer sections: each public_key= starts a new peer.
    Multiple allowed_ip= lines are collected into a list.
    """
    from wireguard_go_bridge.keys import derive_public_key

    device = DeviceStatus()
    current_peer: PeerStatus | None = None

    for line in ipc_dump.splitlines():
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)

        if key == "private_key":
            device.public_key = derive_public_key(value)
        elif key == "listen_port" and current_peer is None:
            device.listen_port = int(value)
        elif key == "fwmark" and current_peer is None:
            device.fwmark = int(value)
        elif key == "public_key":
            # New peer section
            current_peer = PeerStatus(public_key=value)
            device.peers.append(current_peer)
        elif current_peer is not None:
            if key == "endpoint":
                current_peer.endpoint = value
            elif key == "allowed_ip":
                current_peer.allowed_ips.append(value)
            elif key == "last_handshake_time_sec":
                current_peer.latest_handshake = int(value)
            elif key == "last_handshake_time_nsec":
                pass  # sec precision sufficient
            elif key == "rx_bytes":
                current_peer.rx_bytes = int(value)
            elif key == "tx_bytes":
                current_peer.tx_bytes = int(value)
            elif key == "persistent_keepalive_interval":
                current_peer.keepalive = int(value)
            # Unknown keys silently ignored

    return device
