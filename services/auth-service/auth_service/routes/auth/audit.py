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

Audit log endpoint — paginated, filterable, superadmin only.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query, Request

from auth_service.crypto.jwt import TokenPayload
from auth_service.middleware.auth import require_superadmin
from auth_service.models import ApiOk, AuditLogPage

router = APIRouter()


@router.get("/audit", response_model=ApiOk[AuditLogPage])
def get_audit_log(
    request: Request,
    _payload: TokenPayload = Depends(require_superadmin),
    page: int = Query(1, ge=1, description="Page number (1-based)"),
    limit: int = Query(25, ge=1, le=100, description="Entries per page (max 100)"),
    action: str | None = Query(None, description="Filter by action type"),
    username: str | None = Query(None, description="Filter by username"),
    ip: str | None = Query(None, description="Filter by IP address"),
    order: str = Query("desc", pattern="^(asc|desc)$", description="Sort direction: asc or desc"),
    sort_by: str = Query("timestamp", pattern="^timestamp$", description="Sort column (timestamp only)"),
):
    """Paginated audit log with filtering and ordering. Superadmin only."""
    db = request.state.db
    result = db.get_audit_logs_paginated(
        page=page, limit=limit, action=action, username=username, ip=ip,
        order=order, sort_by=sort_by,
    )
    return ApiOk(data=AuditLogPage(**result))
