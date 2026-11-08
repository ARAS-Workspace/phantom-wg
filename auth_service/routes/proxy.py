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

Authenticated reverse proxy to daemon UDS.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response

from auth_service.audit import audit_log
from auth_service.errors import ApiException
from auth_service.middleware.auth import AuthPayload

if TYPE_CHECKING:
    from auth_service.config import AuthConfig
    from auth_service.crypto.jwt import TokenPayload

log = logging.getLogger("phantom-auth")
router = APIRouter(prefix="/api", tags=["proxy"])


class Role(StrEnum):
    """Roles a token carries."""

    ADMIN = "admin"
    SUPERADMIN = "superadmin"


class Access(StrEnum):
    """What a daemon route asks of the caller."""

    VIEW = "view"          # reads state, carries no client key
    OPERATE = "operate"    # changes VPN state, or reads a client key
    CUSTODY = "custody"    # moves the whole data set, every client key with it


GRANTS: dict[Access, frozenset[Role]] = {
    Access.VIEW:    frozenset({Role.ADMIN, Role.SUPERADMIN}),
    Access.OPERATE: frozenset({Role.ADMIN, Role.SUPERADMIN}),
    Access.CUSTODY: frozenset({Role.SUPERADMIN}),
}


@dataclass(frozen=True, slots=True)
class Route:
    """The access a daemon route needs, and the body limit it takes."""

    access: Access
    large_body: bool = False

    def permits(self, payload: TokenPayload) -> bool:
        """Whether this token's role holds the route's access."""
        return payload.role in GRANTS[self.access]

    def max_body(self, config: AuthConfig) -> int:
        """Request body limit for the route, in bytes."""
        return config.proxy_backup_max_body if self.large_body else config.proxy_max_body


# Every daemon route the proxy forwards, matched exactly on method and path.
# A request outside this table does not reach the daemon, and the URL sent to
# the daemon is the table's path.
ROUTES: dict[tuple[str, str], Route] = {
    # Backup
    ("POST", "/api/core/backup/export"):         Route(Access.CUSTODY, large_body=True),
    ("POST", "/api/core/backup/import"):         Route(Access.CUSTODY, large_body=True),
    # Clients
    ("POST", "/api/core/clients/assign"):        Route(Access.OPERATE),
    ("POST", "/api/core/clients/config"):        Route(Access.OPERATE),
    ("POST", "/api/core/clients/get"):           Route(Access.OPERATE),
    ("GET", "/api/core/clients/list"):           Route(Access.VIEW),
    ("POST", "/api/core/clients/revoke"):        Route(Access.OPERATE),
    # Firewall
    ("POST", "/api/core/firewall/groups/get"):   Route(Access.VIEW),
    ("GET", "/api/core/firewall/groups/list"):   Route(Access.VIEW),
    ("POST", "/api/core/firewall/routing/list"): Route(Access.VIEW),
    ("POST", "/api/core/firewall/rules/list"):   Route(Access.VIEW),
    ("GET", "/api/core/firewall/table"):         Route(Access.VIEW),
    # Hello
    ("GET", "/api/core/hello"):                  Route(Access.VIEW),
    # Network
    ("GET", "/api/core/network"):                Route(Access.VIEW),
    ("POST", "/api/core/network/cidr"):          Route(Access.OPERATE),
    ("GET", "/api/core/network/validate"):       Route(Access.VIEW),
    # WireGuard
    ("GET", "/api/core/wireguard"):              Route(Access.VIEW),
    ("POST", "/api/core/wireguard/peer"):        Route(Access.VIEW),
    # DNS
    ("POST", "/api/dns/change"):                 Route(Access.OPERATE),
    ("POST", "/api/dns/get"):                    Route(Access.VIEW),
    # Multihop
    ("POST", "/api/multihop/config"):            Route(Access.OPERATE),
    ("POST", "/api/multihop/disable"):           Route(Access.OPERATE),
    ("POST", "/api/multihop/enable"):            Route(Access.OPERATE),
    ("POST", "/api/multihop/import"):            Route(Access.OPERATE),
    ("GET", "/api/multihop/list"):               Route(Access.VIEW),
    ("POST", "/api/multihop/remove"):            Route(Access.OPERATE),
    ("GET", "/api/multihop/status"):             Route(Access.VIEW),
    ("POST", "/api/multihop/update"):            Route(Access.OPERATE),
}


def _resolve_user_id(request: Request, username: str) -> str | None:
    """Resolve user_id from username for audit logging."""
    user = request.state.db.get_user_by_username(username)
    return user.id if user else None


def _audit_detail(method: str, path: str, query: str, status: int) -> dict:
    """Build audit detail dict for a proxy request."""
    detail: dict = {"method": method, "path": f"/api/{path}", "status": status}
    if query:
        detail["query"] = query
    return detail


@router.api_route(
    "/{path:path}",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"],
)
async def proxy(
    path: str,
    request: Request,
    payload: AuthPayload,
):
    """Forward authenticated request to daemon over UDS."""
    config = request.app.state.config
    client = request.app.state.proxy_client
    db = request.state.db
    route = f"/api/{path}"
    query = str(request.url.query) if request.url.query else ""
    user_id = _resolve_user_id(request, payload.sub)

    route_access = ROUTES.get((request.method, route))
    if route_access is None:
        audit_log(db, request, "proxy_request",
                  detail=_audit_detail(request.method, path, query, 404),
                  user_id=user_id)
        raise ApiException(404, "NOT_FOUND")

    if not route_access.permits(payload):
        audit_log(db, request, "proxy_request",
                  detail=_audit_detail(request.method, path, query, 403),
                  user_id=user_id)
        raise ApiException(403, "SUPERADMIN_REQUIRED")

    target_url = f"{config.proxy_base_url}{route}"
    if query:
        target_url = f"{target_url}?{query}"

    body = await request.body()
    if len(body) > route_access.max_body(config):
        audit_log(db, request, "proxy_request",
                  detail=_audit_detail(request.method, path, query, 413),
                  user_id=user_id)
        return JSONResponse(
            status_code=413,
            content={"ok": False, "error_code": "BODY_TOO_LARGE"},
        )

    headers = {}
    for key, value in request.headers.items():
        if key.lower() not in ("host", "authorization", "content-length", "transfer-encoding"):
            headers[key] = value

    # noinspection PyBroadException
    try:
        response = await client.request(
            method=request.method,
            url=target_url,
            content=body if body else None,
            headers=headers,
        )
    except Exception:
        log.exception("Daemon proxy error")
        audit_log(db, request, "proxy_request",
                  detail=_audit_detail(request.method, path, query, 502),
                  user_id=user_id)
        return JSONResponse(
            status_code=502,
            content={"ok": False, "error_code": "SERVICE_UNAVAILABLE"},
        )

    audit_log(db, request, "proxy_request",
              detail=_audit_detail(request.method, path, query, response.status_code),
              user_id=user_id)

    passthrough_headers = {
        k: v
        for k, v in response.headers.items()
        if k.lower() not in ("content-length", "transfer-encoding", "content-encoding")
    }

    content_type = response.headers.get("content-type", "")
    if content_type.startswith("application/json"):
        return JSONResponse(
            status_code=response.status_code,
            content=response.json(),
            headers=passthrough_headers,
        )

    # Binary/non-JSON responses — pass through raw bytes
    return Response(
        content=response.content,
        status_code=response.status_code,
        media_type=content_type,
        headers=passthrough_headers,
    )
