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

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse, Response

from auth_service.audit import audit_log
from auth_service.crypto.jwt import TokenPayload
from auth_service.middleware.auth import require_auth

log = logging.getLogger("phantom-auth")
router = APIRouter(prefix="/api", tags=["proxy"])


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
    payload: TokenPayload = Depends(require_auth),
):
    """Forward authenticated request to daemon over UDS."""
    config = request.app.state.config
    client = request.app.state.proxy_client
    db = request.state.db
    target_url = f"{config.proxy_base_url}/api/{path}"
    query = str(request.url.query) if request.url.query else ""
    if query:
        target_url = f"{target_url}?{query}"

    user_id = _resolve_user_id(request, payload.sub)

    body = await request.body()
    if len(body) > config.proxy_max_body:
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

    try:
        response = await client.request(
            method=request.method,
            url=target_url,
            content=body if body else None,
            headers=headers,
        )
    except Exception as exc:
        log.error("Daemon proxy error: %s", exc)
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
