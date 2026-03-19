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

Client CRUD endpoints: assign, list, get, revoke, config export.
"""

from __future__ import annotations

import base64
from typing import Literal

from fastapi import APIRouter, Query, Request
from pydantic import BaseModel, Field

from phantom_daemon.base.errors import DaemonHTTPException
from phantom_daemon.base.services.wireguard.config import build_client_config
from phantom_daemon.modules._envelope import ApiErr, ApiOk


# ── Models ───────────────────────────────────────────────────────


class ClientNameRequest(BaseModel):
    """Request body identifying a client by name."""

    name: str = Field(
        min_length=1, max_length=64, pattern=r"^[a-zA-Z0-9_-]+$",
        description="Unique client name (alphanumeric, hyphens, underscores).",
    )


class ConfigExportRequest(BaseModel):
    """Request body for exporting a client WireGuard configuration."""

    name: str = Field(
        min_length=1, max_length=64, pattern=r"^[a-zA-Z0-9_-]+$",
        description="Client name to export config for.",
    )
    version: Literal["v4", "v6", "hybrid"] = Field(
        description="IP version: v4 (IPv4-only), v6 (IPv6-only), or hybrid (dual-stack).",
    )


class ClientRecord(BaseModel):
    """Full client record including private key material."""

    id: str
    name: str
    ipv4_address: str
    ipv6_address: str
    private_key_hex: str
    public_key_hex: str
    preshared_key_hex: str
    created_at: str
    updated_at: str


class ClientSummary(BaseModel):
    """Client summary without private key material (used in list responses)."""

    id: str
    name: str
    ipv4_address: str
    ipv6_address: str
    public_key_hex: str
    created_at: str
    updated_at: str


class ClientListResponse(BaseModel):
    """Paginated client list response."""

    clients: list[ClientSummary]
    total: int
    page: int
    limit: int
    pages: int
    order: str


# ── Router ───────────────────────────────────────────────────────

router = APIRouter(tags=["clients"])


@router.post(
    "/assign",
    response_model=ApiOk[ClientRecord],
    status_code=201,
    responses={400: {"model": ApiErr}, 409: {"model": ApiErr}},
    summary="Assign Client",
    description="Create a new WireGuard client with the given name. Generates a "
    "key pair, allocates IPv4/IPv6 addresses from the pool, and registers the "
    "peer on the WireGuard interface. Returns 409 if the name already exists, "
    "400 if the pool is full.",
)
async def assign_client(body: ClientNameRequest, request: Request):
    wallet = request.app.state.wallet
    wg = request.app.state.wg
    env = request.app.state.env

    result = wallet.assign_client(body.name)
    try:
        wg.add_peer(result, env.keepalive)
    except Exception:
        wallet.revoke_client(body.name)
        raise
    return ApiOk(data=ClientRecord(**result))


@router.get(
    "/list",
    response_model=ApiOk[ClientListResponse],
    summary="List Clients",
    description="Return a paginated list of all WireGuard clients. Supports "
    "search by name and ascending/descending order by creation date.",
)
async def list_clients(
    request: Request,
    page: int = Query(1, ge=1),
    limit: int = Query(25, ge=1, le=100),
    search: str | None = Query(None),
    order: str = Query("desc", pattern="^(asc|desc)$"),
):
    wallet = request.app.state.wallet
    result = wallet.list_clients_paginated(
        page=page, limit=limit, search=search, order=order
    )
    summaries = [ClientSummary(**c) for c in result["clients"]]
    return ApiOk(data=ClientListResponse(
        clients=summaries,
        total=result["total"],
        page=result["page"],
        limit=result["limit"],
        pages=result["pages"],
        order=result["order"],
    ))


@router.post(
    "/get",
    response_model=ApiOk[ClientRecord],
    responses={404: {"model": ApiErr}},
    summary="Get Client",
    description="Retrieve the full record for a single client including private "
    "key material. Returns 404 if the client does not exist.",
)
async def get_client(body: ClientNameRequest, request: Request):
    wallet = request.app.state.wallet
    result = wallet.get_client(body.name)
    if result is None:
        raise DaemonHTTPException(404, "CLIENT_NOT_FOUND", f"Client not found: {body.name}")
    return ApiOk(data=ClientRecord(**result))


@router.post(
    "/config",
    response_model=ApiOk[str],
    responses={400: {"model": ApiErr}, 404: {"model": ApiErr}},
    summary="Export Client Config",
    description="Generate a WireGuard configuration file for the given client and "
    "IP version. Returns the config as a base64-encoded string. Returns 404 if "
    "the client does not exist, 400 if the required endpoint is not configured.",
)
async def export_config(body: ConfigExportRequest, request: Request):
    wallet = request.app.state.wallet
    env = request.app.state.env
    server_keys = request.app.state.server_keys

    client = wallet.get_client(body.name)
    if client is None:
        raise DaemonHTTPException(404, "CLIENT_NOT_FOUND", f"Client not found: {body.name}")

    if body.version in ("v4", "hybrid") and not env.endpoint_v4:
        raise DaemonHTTPException(400, "ENDPOINT_V4_NOT_CONFIGURED", "endpoint_v4 is not configured")
    if body.version in ("v6", "hybrid") and not env.endpoint_v6:
        raise DaemonHTTPException(400, "ENDPOINT_V6_NOT_CONFIGURED", "endpoint_v6 is not configured")

    if body.version in ("v4", "hybrid"):
        endpoint = f"{env.endpoint_v4}:{env.listen_port}"
    else:
        endpoint = f"{env.endpoint_v6}:{env.listen_port}"

    dns_v4 = wallet.get_dns("v4")
    dns_v6 = wallet.get_dns("v6")

    conf = build_client_config(
        version=body.version,
        client_private_key_hex=client["private_key_hex"],
        client_ipv4=client["ipv4_address"],
        client_ipv6=client["ipv6_address"],
        server_public_key_hex=server_keys.public_key_hex,
        preshared_key_hex=client["preshared_key_hex"],
        dns_v4=dns_v4,
        dns_v6=dns_v6,
        endpoint=endpoint,
        keepalive=env.keepalive,
        mtu=env.mtu,
    )
    b64 = base64.b64encode(conf.encode()).decode()
    return ApiOk(data=b64)


@router.post(
    "/revoke",
    response_model=ApiOk[dict],
    responses={400: {"model": ApiErr}},
    summary="Revoke Client",
    description="Remove a WireGuard client by name. Deletes the peer from the "
    "interface and releases the allocated IP addresses back to the pool. "
    "Returns 400 if the client does not exist.",
)
async def revoke_client(body: ClientNameRequest, request: Request):
    wallet = request.app.state.wallet
    wg = request.app.state.wg
    env = request.app.state.env

    client = wallet.get_client(body.name)
    if client is None:
        raise DaemonHTTPException(400, "CLIENT_NOT_FOUND", f"Client not found: {body.name}")

    wg.remove_peer(client["public_key_hex"])
    try:
        wallet.revoke_client(body.name)
    except Exception:
        wg.add_peer(client, env.keepalive)
        raise
    return ApiOk(data={"status": "revoked", "code": "CLIENT_REVOKED"})
