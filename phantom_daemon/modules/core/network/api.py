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

Network status, CIDR change, and pool validation endpoints.
"""

from __future__ import annotations

import json

from fastapi import APIRouter, Request
from pydantic import BaseModel, Field

from phantom_daemon.modules._envelope import ApiErr, ApiOk


# ── Models ───────────────────────────────────────────────────────


class PoolStats(BaseModel):
    """IP address pool utilization counters."""

    total: int
    assigned: int
    free: int


class DnsDetail(BaseModel):
    """Primary and secondary DNS server addresses for one IP family."""

    primary: str
    secondary: str


class NetworkStatus(BaseModel):
    """Current network configuration including subnets, DNS, and pool stats."""

    ipv4_subnet: str
    ipv6_subnet: str
    dns_v4: DnsDetail
    dns_v6: DnsDetail
    pool: PoolStats


class ChangeCidrRequest(BaseModel):
    """Request body for changing the IPv4 CIDR prefix length."""

    prefix: int = Field(
        ge=16, le=30,
        description="New IPv4 CIDR prefix length (16–30). Expanding the prefix "
        "migrates existing clients to the new subnet.",
    )


class ChangeCidrResponse(BaseModel):
    """Result after a CIDR change including updated subnets and pool stats."""

    ipv4_subnet: str
    ipv6_subnet: str
    pool: PoolStats


class ValidatePoolResponse(BaseModel):
    """Pool integrity validation result."""

    valid: bool
    errors: list[str]


# ── Router ───────────────────────────────────────────────────────

router = APIRouter(tags=["network"])


@router.get(
    "",
    response_model=ApiOk[NetworkStatus],
    summary="Network Status",
    description="Return current IPv4/IPv6 subnets, DNS configuration for both "
    "address families, and IP address pool utilization (total, assigned, free).",
)
async def network_status(request: Request):
    wallet = request.app.state.wallet
    config = wallet.get_all_config()
    dns_v4 = json.loads(config["dns_v4"])
    dns_v6 = json.loads(config["dns_v6"])
    return ApiOk(data=NetworkStatus(
        ipv4_subnet=config["ipv4_subnet"],
        ipv6_subnet=config["ipv6_subnet"],
        dns_v4=DnsDetail(**dns_v4),
        dns_v6=DnsDetail(**dns_v6),
        pool=PoolStats(
            total=wallet.count_users(),
            assigned=wallet.count_assigned(),
            free=wallet.count_free(),
        ),
    ))


@router.post(
    "/cidr",
    response_model=ApiOk[ChangeCidrResponse],
    responses={400: {"model": ApiErr}},
    summary="Change CIDR",
    description="Change the IPv4 CIDR prefix length. The pool is expanded or "
    "contracted and existing clients are migrated to the new subnet. "
    "Returns 400 if the new prefix cannot accommodate current clients.",
)
async def change_cidr(body: ChangeCidrRequest, request: Request):
    wallet = request.app.state.wallet
    wallet.change_cidr(body.prefix)
    config = wallet.get_all_config()
    return ApiOk(data=ChangeCidrResponse(
        ipv4_subnet=config["ipv4_subnet"],
        ipv6_subnet=config["ipv6_subnet"],
        pool=PoolStats(
            total=wallet.count_users(),
            assigned=wallet.count_assigned(),
            free=wallet.count_free(),
        ),
    ))


@router.get(
    "/validate",
    response_model=ApiOk[ValidatePoolResponse],
    summary="Validate Pool",
    description="Run integrity checks on the IP address pool. Returns a list of "
    "errors if inconsistencies are found (e.g. duplicate addresses, out-of-range "
    "allocations). An empty error list means the pool is healthy.",
)
async def validate_pool(request: Request):
    wallet = request.app.state.wallet
    errors = wallet.validate_pool()
    return ApiOk(data=ValidatePoolResponse(valid=len(errors) == 0, errors=errors))
