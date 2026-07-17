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

Audit logging helper.
"""

from __future__ import annotations

import ipaddress

from fastapi import Request

from auth_service.db.repository import AuthDB


def _is_trusted(ip_str: str, trusted) -> bool:
    """True if ip_str parses as an address inside a trusted network."""
    try:
        addr = ipaddress.ip_address(ip_str)
    except ValueError:
        return False
    return any(addr in net for net in trusted)


def get_client_ip(request: Request) -> str:
    """Resolve the real client IP behind trusted proxies.

    X-Forwarded-For is only honored when the connecting peer is a
    trusted proxy (config.trusted_proxies). Entries are then walked
    right to left — the rightmost was appended by the nearest proxy —
    skipping trusted hops; the first untrusted address is the client.

    The leftmost entries are client-supplied and never trusted blindly:
    nginx appends to the incoming header ($proxy_add_x_forwarded_for),
    so a spoofed prefix survives the proxy but is never reached here.
    A direct connection from an untrusted peer cannot spoof at all.
    """
    peer = request.client.host if request.client else ""
    trusted = request.app.state.config.trusted_proxies
    if not peer or not _is_trusted(peer, trusted):
        return peer

    header = request.headers.get("x-forwarded-for", "")
    entries = [e.strip() for e in header.split(",") if e.strip()]
    candidate = peer
    for entry in reversed(entries):
        if not _is_trusted(entry, trusted):
            try:
                ipaddress.ip_address(entry)
            except ValueError:
                break  # malformed hop — keep the last verified address
            return entry
        candidate = entry
    return candidate


def audit_log(
    db: AuthDB,
    request: Request,
    action: str,
    detail: dict | None = None,
    user_id: str | None = None,
) -> None:
    """Write an audit log entry."""
    db.add_audit_log(
        action=action,
        detail=detail,
        user_id=user_id,
        ip_address=get_client_ip(request),
    )
