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
import logging

from fastapi import APIRouter, Request
from pydantic import BaseModel, Field

from phantom_daemon.base.logging import LOGGER_NAME
from phantom_daemon.base.services.firewall.service import parse_allowed_ips_families
from phantom_daemon.modules._envelope import ApiErr, ApiOk

log = logging.getLogger(LOGGER_NAME)


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


# ── Kernel resync ────────────────────────────────────────────────


def _resync_kernel(state, old_v4: str, new_v4: str) -> None:
    """Rebuild kernel state from the wallet after a CIDR change.

    The subnet is baked into peer allowed_ips, the server interface prefix
    and the firewall presets at their own resolve time, so changing the
    wallet alone leaves all three stale. Same calls the lifespan makes on
    boot, in the same order.

    The wallet is not rolled back on failure: reverting is another
    change_cidr, which carries the same risk and re-slots every client a
    second time. Kernel state is rebuilt from the DB on every boot, so a
    restart is the recovery path — say so loudly instead.
    """
    wallet, wg, fw, env = state.wallet, state.wg, state.fw, state.env
    ipv4_subnet = wallet.get_config("ipv4_subnet")
    ipv6_subnet = wallet.get_config("ipv6_subnet")

    try:
        # Peers first, mirroring lifespan: allowed_ips are pinned /32 + /128
        # to each client's address, and change_cidr may have re-slotted them.
        wg.fast_sync(wallet=wallet, server_keys=state.server_keys, env=env)
        wg.update_addresses(ipv4_subnet=ipv4_subnet, ipv6_subnet=ipv6_subnet)

        # Core carries the masquerade source; multihop carries it again in
        # the policy rule that steers a client into the exit table.
        fw.bootstrap(env=env, wallet=wallet)
        exit_data = None
        if state.exit_store.is_enabled():
            exit_data = state.exit_store.get_exit(state.exit_store.get_active())
        if exit_data:
            has_v4, has_v6 = parse_allowed_ips_families(exit_data["allowed_ips"])
        else:
            has_v4 = has_v6 = False
        fw.resync_multihop(wallet=wallet, has_v4=has_v4, has_v6=has_v6)
    except Exception:
        log.critical(
            "cidr changed %s -> %s but kernel resync failed — restart the "
            "daemon to rebuild kernel state from the database",
            old_v4, new_v4,
        )
        raise

    log.info("cidr changed %s -> %s: kernel resynced", old_v4, new_v4)


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
    state = request.app.state
    wallet = state.wallet
    old_v4 = wallet.get_config("ipv4_subnet")

    wallet.change_cidr(body.prefix)
    config = wallet.get_all_config()

    if config["ipv4_subnet"] != old_v4:
        _resync_kernel(state, old_v4, config["ipv4_subnet"])

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
