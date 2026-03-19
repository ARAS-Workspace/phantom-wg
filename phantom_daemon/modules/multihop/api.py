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

Multihop exit tunnel endpoints: import, remove, list, enable, disable, status.
"""

from __future__ import annotations

from fastapi import APIRouter, Request
from pydantic import BaseModel, Field

from phantom_daemon.base.errors import DaemonHTTPException
from phantom_daemon.base.exit_store import parse_wireguard_config
from phantom_daemon.base.services.firewall.service import (
    MULTIHOP_PRESET_NAME,
    resolve_multihop_preset,
)
from phantom_daemon.base.services.wireguard import WG_INTERFACE_NAME_EXIT
from phantom_daemon.base.services.wireguard.ipc import build_exit_config
from phantom_daemon.base.services.wireguard.service import open_wireguard
from phantom_daemon.modules._envelope import ApiErr, ApiOk


# ── Models ───────────────────────────────────────────────────────


class ImportRequest(BaseModel):
    """Request body for importing an exit server configuration."""

    name: str = Field(
        min_length=1, max_length=64, pattern=r"^[a-zA-Z0-9_-]+$",
        description="Unique name for this exit server.",
    )
    config: str = Field(
        min_length=1,
        description="WireGuard .conf file contents (plain text, not base64).",
    )


class ExitNameRequest(BaseModel):
    """Request body identifying an exit server by name."""

    name: str = Field(
        min_length=1, max_length=64, pattern=r"^[a-zA-Z0-9_-]+$",
        description="Exit server name.",
    )


class ExitSummary(BaseModel):
    """Summary of an imported exit server configuration."""

    id: str
    name: str
    endpoint: str
    address: str
    public_key_hex: str
    allowed_ips: str
    keepalive: int


class ExitListResponse(BaseModel):
    """List of all imported exit servers with current multihop state."""

    exits: list[ExitSummary]
    total: int
    enabled: bool
    active: str


class PeerStatus(BaseModel):
    """Live WireGuard peer statistics for the active exit tunnel."""

    endpoint: str
    latest_handshake: int
    rx_bytes: int
    tx_bytes: int


class MultihopStatus(BaseModel):
    """Current multihop state including active exit and live peer stats."""

    enabled: bool
    active: str
    exit: ExitSummary | None
    peer: PeerStatus | None


# ── Router ───────────────────────────────────────────────────────

router = APIRouter(tags=["multihop"])


@router.post(
    "/import",
    response_model=ApiOk[ExitSummary],
    status_code=201,
    responses={400: {"model": ApiErr}},
    summary="Import Exit",
    description="Import a WireGuard .conf file as a new exit server configuration. "
    "Parses the config to extract endpoint, keys, and allowed IPs. "
    "Returns 400 if the config is invalid or the name already exists.",
)
async def import_exit(body: ImportRequest, request: Request):
    """Import a WireGuard .conf as an exit configuration."""
    exit_store = request.app.state.exit_store

    try:
        parsed = parse_wireguard_config(body.config)
    except ValueError as exc:
        raise DaemonHTTPException(400, "INVALID_EXIT_CONFIG", str(exc))

    result = exit_store.add_exit(
        name=body.name,
        endpoint=parsed.endpoint,
        address=parsed.address,
        private_key_hex=parsed.private_key_hex,
        public_key_hex=parsed.public_key_hex,
        preshared_key_hex=parsed.preshared_key_hex,
        allowed_ips=parsed.allowed_ips,
        keepalive=parsed.keepalive,
    )
    return ApiOk(data=ExitSummary(
        id=result["id"],
        name=result["name"],
        endpoint=result["endpoint"],
        address=result["address"],
        public_key_hex=result["public_key_hex"],
        allowed_ips=result["allowed_ips"],
        keepalive=result["keepalive"],
    ))


@router.post(
    "/remove",
    response_model=ApiOk[dict],
    responses={400: {"model": ApiErr}},
    summary="Remove Exit",
    description="Delete an exit server configuration by name. The exit must not "
    "be currently active — disable multihop first if needed.",
)
async def remove_exit(body: ExitNameRequest, request: Request):
    """Remove an exit configuration. Must not be active."""
    exit_store = request.app.state.exit_store
    exit_store.remove_exit(body.name)
    return ApiOk(data={"status": "removed", "code": "EXIT_REMOVED"})


@router.get(
    "/list",
    response_model=ApiOk[ExitListResponse],
    summary="List Exits",
    description="Return all imported exit server configurations along with the "
    "current multihop state (enabled/disabled and active exit name).",
)
async def list_exits(request: Request):
    """List all exit configurations and current state."""
    exit_store = request.app.state.exit_store
    exits = exit_store.list_exits()
    summaries = [
        ExitSummary(
            id=e["id"],
            name=e["name"],
            endpoint=e["endpoint"],
            address=e["address"],
            public_key_hex=e["public_key_hex"],
            allowed_ips=e["allowed_ips"],
            keepalive=e["keepalive"],
        )
        for e in exits
    ]
    return ApiOk(data=ExitListResponse(
        exits=summaries,
        total=len(summaries),
        enabled=exit_store.is_enabled(),
        active=exit_store.get_active(),
    ))


@router.post(
    "/enable",
    response_model=ApiOk[dict],
    responses={400: {"model": ApiErr}, 404: {"model": ApiErr}},
    summary="Enable Multihop",
    description="Activate multihop routing through the named exit server. Creates "
    "the exit WireGuard interface, applies firewall forwarding rules, and starts "
    "the tunnel. Multihop must be disabled first — switching exits requires "
    "disable then re-enable. Returns 404 if the exit does not exist.",
)
async def enable_multihop(body: ExitNameRequest, request: Request):
    """Enable multihop with the given exit."""
    exit_store = request.app.state.exit_store
    env = request.app.state.env
    wallet = request.app.state.wallet
    fw = request.app.state.fw

    if exit_store.is_enabled():
        return ApiOk(data={"status": "already_active", "code": "MULTIHOP_ALREADY_ACTIVE"})

    exit_data = exit_store.get_exit(body.name)
    if exit_data is None:
        raise DaemonHTTPException(404, "EXIT_NOT_FOUND", f"Exit not found: {body.name}")

    config = build_exit_config(
        private_key_hex=exit_data["private_key_hex"],
        peer_public_key_hex=exit_data["public_key_hex"],
        peer_preshared_key_hex=exit_data["preshared_key_hex"],
        endpoint=exit_data["endpoint"],
        allowed_ips=exit_data["allowed_ips"],
        keepalive=exit_data["keepalive"],
    )

    wg_exit = open_wireguard(
        state_dir=env.state_dir, mtu=env.mtu,
        ifname=WG_INTERFACE_NAME_EXIT,
    )
    try:
        wg_exit._bridge.ipc_set(config)
        wg_exit.up()
        wg_exit.apply_exit_interface(exit_data["address"])

        ipv4_subnet = wallet.get_config("ipv4_subnet") or ""
        mh_spec = resolve_multihop_preset(ipv4_subnet=ipv4_subnet)
        fw.apply_preset(mh_spec)
    except Exception:
        # Rollback: always attempt cleanup regardless of which step failed.
        # remove_preset is safe to call even if preset was never applied.
        try:
            fw.remove_preset(MULTIHOP_PRESET_NAME)
        except (RuntimeError, OSError):
            pass
        try:
            wg_exit.down()
        except (RuntimeError, OSError):
            pass
        wg_exit.close()
        raise

    request.app.state.wg_exit = wg_exit
    exit_store.activate(body.name)
    return ApiOk(data={"status": "enabled", "code": "MULTIHOP_ENABLED"})


@router.post(
    "/disable",
    response_model=ApiOk[dict],
    responses={400: {"model": ApiErr}},
    summary="Disable Multihop",
    description="Deactivate multihop routing. Tears down the exit WireGuard "
    "interface and removes the firewall forwarding rules. Client traffic "
    "returns to the default direct route.",
)
async def disable_multihop(request: Request):
    """Disable multihop — tear down exit device and remove firewall preset."""
    exit_store = request.app.state.exit_store
    fw = request.app.state.fw
    wg_exit = request.app.state.wg_exit

    if not exit_store.is_enabled():
        return ApiOk(data={"status": "already_disabled", "code": "MULTIHOP_ALREADY_DISABLED"})

    try:
        fw.remove_preset(MULTIHOP_PRESET_NAME)
    except (RuntimeError, OSError):
        pass

    if wg_exit is not None:
        wg_exit.down()
        wg_exit.close()
        request.app.state.wg_exit = None

    exit_store.deactivate()
    return ApiOk(data={"status": "disabled", "code": "MULTIHOP_DISABLED"})


@router.get(
    "/status",
    response_model=ApiOk[MultihopStatus],
    summary="Multihop Status",
    description="Return current multihop state: enabled/disabled, active exit "
    "server details, and live WireGuard peer statistics (handshake, RX/TX) "
    "for the exit tunnel.",
)
async def multihop_status(request: Request):
    """Return current multihop state, active exit info, and live peer stats."""
    exit_store = request.app.state.exit_store
    wg_exit = request.app.state.wg_exit
    enabled = exit_store.is_enabled()
    active = exit_store.get_active()

    exit_summary = None
    peer_status = None

    if active:
        exit_data = exit_store.get_exit(active)
        if exit_data:
            exit_summary = ExitSummary(
                id=exit_data["id"],
                name=exit_data["name"],
                endpoint=exit_data["endpoint"],
                address=exit_data["address"],
                public_key_hex=exit_data["public_key_hex"],
                allowed_ips=exit_data["allowed_ips"],
                keepalive=exit_data["keepalive"],
            )

    if wg_exit is not None:
        try:
            status = wg_exit.get_status()
            if status.peers:
                p = status.peers[0]
                peer_status = PeerStatus(
                    endpoint=p.endpoint,
                    latest_handshake=p.latest_handshake,
                    rx_bytes=p.rx_bytes,
                    tx_bytes=p.tx_bytes,
                )
        except (RuntimeError, OSError):
            pass

    return ApiOk(data=MultihopStatus(
        enabled=enabled,
        active=active,
        exit=exit_summary,
        peer=peer_status,
    ))
