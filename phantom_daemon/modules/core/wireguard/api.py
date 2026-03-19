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

WireGuard status endpoints: device overview and peer lookup.
"""

from __future__ import annotations

from fastapi import APIRouter, Request
from pydantic import BaseModel, Field

from phantom_daemon.base.errors import DaemonHTTPException
from phantom_daemon.modules._envelope import ApiErr, ApiOk


# ── Models ───────────────────────────────────────────────────────


class InterfaceInfo(BaseModel):
    """WireGuard interface metadata."""

    public_key: str
    listen_port: int
    fwmark: int


class PeerInfo(BaseModel):
    """Live status of a single WireGuard peer from the kernel interface."""

    public_key: str
    name: str | None
    endpoint: str
    allowed_ips: list[str]
    latest_handshake: int
    rx_bytes: int
    tx_bytes: int
    keepalive: int


class WireGuardStatus(BaseModel):
    """Full WireGuard interface status including all peers."""

    interface: InterfaceInfo
    peers: list[PeerInfo]
    total_peers: int


class PeerQuery(BaseModel):
    """Request body to look up a peer by client name."""

    name: str = Field(
        min_length=1, max_length=64, pattern=r"^[a-zA-Z0-9_-]+$",
        description="Client name to look up.",
    )


# ── Router ───────────────────────────────────────────────────────

router = APIRouter(tags=["wireguard"])


@router.get(
    "",
    response_model=ApiOk[WireGuardStatus],
    summary="WireGuard Status",
    description="Return the current WireGuard interface status including public "
    "key, listen port, and all registered peers with their live traffic "
    "statistics, handshake timestamps, and connection endpoints.",
)
async def get_status(request: Request):
    wg = request.app.state.wg
    wallet = request.app.state.wallet

    status = wg.get_status()

    clients = wallet.list_clients()
    client_map = {c["public_key_hex"]: c for c in clients}

    peers = [
        PeerInfo(
            public_key=p.public_key,
            name=client_map[p.public_key]["name"] if p.public_key in client_map else None,
            endpoint=p.endpoint,
            allowed_ips=p.allowed_ips,
            latest_handshake=p.latest_handshake,
            rx_bytes=p.rx_bytes,
            tx_bytes=p.tx_bytes,
            keepalive=p.keepalive,
        )
        for p in status.peers
    ]

    return ApiOk(
        data=WireGuardStatus(
            interface=InterfaceInfo(
                public_key=status.public_key,
                listen_port=status.listen_port,
                fwmark=status.fwmark,
            ),
            peers=peers,
            total_peers=len(peers),
        )
    )


@router.post(
    "/peer",
    response_model=ApiOk[PeerInfo],
    responses={404: {"model": ApiErr}},
    summary="Lookup Peer",
    description="Look up a single peer by client name and return its live "
    "WireGuard status. Returns 404 if the client does not exist or the peer "
    "is not registered on the interface.",
)
async def get_peer(body: PeerQuery, request: Request):
    wg = request.app.state.wg
    wallet = request.app.state.wallet

    client = wallet.get_client(body.name)
    if client is None:
        raise DaemonHTTPException(404, "CLIENT_NOT_FOUND", f"Client not found: {body.name}")

    status = wg.get_status()

    for p in status.peers:
        if p.public_key == client["public_key_hex"]:
            return ApiOk(
                data=PeerInfo(
                    public_key=p.public_key,
                    name=body.name,
                    endpoint=p.endpoint,
                    allowed_ips=p.allowed_ips,
                    latest_handshake=p.latest_handshake,
                    rx_bytes=p.rx_bytes,
                    tx_bytes=p.tx_bytes,
                    keepalive=p.keepalive,
                )
            )

    raise DaemonHTTPException(404, "PEER_NOT_FOUND", f"Peer not found in IPC: {body.name}")
