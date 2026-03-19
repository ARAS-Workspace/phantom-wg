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

DNS configuration endpoints: read and update per address family.
"""

from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Request
from pydantic import BaseModel

from phantom_daemon.modules._envelope import ApiErr, ApiOk


# ── Models ───────────────────────────────────────────────────────


class DnsFamilyRequest(BaseModel):
    """Request body selecting an IP address family."""

    family: Literal["v4", "v6"]


class DnsRecord(BaseModel):
    """DNS server pair for a single address family."""

    family: str
    primary: str
    secondary: str


class ChangeDnsRequest(BaseModel):
    """Request body for updating DNS servers."""

    family: Literal["v4", "v6"]
    primary: str
    secondary: str


# ── Router ───────────────────────────────────────────────────────

router = APIRouter(tags=["dns"])


@router.post(
    "/get",
    response_model=ApiOk[DnsRecord],
    summary="Get DNS",
    description="Return the primary and secondary DNS servers for the given "
    "address family (v4 or v6).",
)
async def get_dns(body: DnsFamilyRequest, request: Request):
    wallet = request.app.state.wallet
    dns = wallet.get_dns(body.family)
    return ApiOk(data=DnsRecord(family=body.family, **dns))


@router.post(
    "/change",
    response_model=ApiOk[DnsRecord],
    responses={400: {"model": ApiErr}},
    summary="Change DNS",
    description="Update the primary and secondary DNS servers for the given "
    "address family. Returns the updated DNS record. Returns 400 if the "
    "provided addresses are invalid.",
)
async def change_dns(body: ChangeDnsRequest, request: Request):
    wallet = request.app.state.wallet
    wallet.change_dns(body.family, body.primary, body.secondary)
    dns = wallet.get_dns(body.family)
    return ApiOk(data=DnsRecord(family=body.family, **dns))
