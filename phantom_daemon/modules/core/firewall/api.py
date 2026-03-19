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

Firewall read-only endpoints: groups, rules, routing, nftables table.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Request
from pydantic import BaseModel

from phantom_daemon.base.errors import DaemonHTTPException
from phantom_daemon.modules._envelope import ApiErr, ApiOk


# ── Models ───────────────────────────────────────────────────────


class GroupNameRequest(BaseModel):
    """Request body identifying a firewall group by name."""

    name: str


class GroupFilterRequest(BaseModel):
    """Optional group filter — omit to list all rules."""

    group: Optional[str] = None


class GroupRecord(BaseModel):
    """Firewall rule group (e.g. base, nat, multihop preset)."""

    id: int
    name: str
    group_type: str
    enabled: bool
    priority: int
    metadata: dict
    created_at: int
    updated_at: int


class FirewallRuleRecord(BaseModel):
    """A single nftables firewall rule within a group."""

    id: int
    group_id: int
    chain: str
    action: str
    family: int
    proto: str
    dport: int
    source: str
    destination: str
    in_iface: str
    out_iface: str
    state_match: str
    comment: str
    position: int
    applied: bool
    nft_handle: int
    created_at: int


class RoutingRuleRecord(BaseModel):
    """An IP routing/policy rule managed by a firewall group."""

    id: int
    group_id: int
    rule_type: str
    from_network: str
    to_network: str
    table_name: str
    table_id: int
    priority: int
    destination: str
    device: str
    applied: bool
    created_at: int


# ── Router ───────────────────────────────────────────────────────

router = APIRouter(tags=["firewall"])


@router.get(
    "/groups/list",
    response_model=ApiOk[list[GroupRecord]],
    summary="List Groups",
    description="Return all firewall rule groups. Each group contains a set of "
    "nftables rules and routing policies applied as a unit.",
)
async def list_groups(request: Request):
    fw = request.app.state.fw
    return ApiOk(data=[GroupRecord(**vars(g)) for g in fw.list_groups()])


@router.post(
    "/groups/get",
    response_model=ApiOk[GroupRecord],
    responses={404: {"model": ApiErr}},
    summary="Get Group",
    description="Retrieve a single firewall group by name. Returns 404 if the "
    "group does not exist.",
)
async def get_group(body: GroupNameRequest, request: Request):
    from firewall_bridge import GroupNotFoundError

    fw = request.app.state.fw
    try:
        g = fw.get_group(body.name)
    except GroupNotFoundError:
        raise DaemonHTTPException(404, "GROUP_NOT_FOUND", f"Group not found: {body.name}")
    return ApiOk(data=GroupRecord(**vars(g)))


@router.post(
    "/rules/list",
    response_model=ApiOk[list[FirewallRuleRecord]],
    summary="List Firewall Rules",
    description="Return nftables firewall rules. Optionally filter by group name "
    "— omit the group field to list rules from all groups.",
)
async def list_firewall_rules(body: GroupFilterRequest, request: Request):
    fw = request.app.state.fw
    return ApiOk(data=[FirewallRuleRecord(**vars(r)) for r in fw.list_firewall_rules(body.group)])


@router.post(
    "/routing/list",
    response_model=ApiOk[list[RoutingRuleRecord]],
    summary="List Routing Rules",
    description="Return IP routing and policy rules. Optionally filter by group "
    "name — omit the group field to list rules from all groups.",
)
async def list_routing_rules(body: GroupFilterRequest, request: Request):
    fw = request.app.state.fw
    return ApiOk(data=[RoutingRuleRecord(**vars(r)) for r in fw.list_routing_rules(body.group)])


@router.get(
    "/table",
    response_model=ApiOk[dict],
    summary="Raw nftables Table",
    description="Return the raw nftables ruleset as JSON (output of "
    "'nft -j list ruleset'). Useful for debugging the live kernel state.",
)
async def list_table(request: Request):
    import json

    fw = request.app.state.fw
    raw = fw.list_table()
    return ApiOk(data=json.loads(raw) if raw else {})
