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

from fastapi import APIRouter, Query, Request

from auth_service.audit import audit_log
from auth_service.middleware.auth import SuperadminPayload
from auth_service.models import ApiOk, AuditLogPage

router = APIRouter()


@router.get("/audit", response_model=ApiOk[AuditLogPage])
def get_audit_log(
    request: Request,
    _payload: SuperadminPayload,
    page: int = Query(1, ge=1, description="Page number (1-based)"),
    limit: int = Query(25, ge=1, le=100, description="Entries per page (max 100)"),
    action: str | None = Query(None, description="Filter by action type"),
    username: str | None = Query(None, description="Filter by username"),
    ip: str | None = Query(None, description="Filter by IP address"),
    order: str = Query("desc", pattern="^(asc|desc)$", description="Sort direction: asc or desc"),
    sort_by: str = Query("timestamp", pattern="^timestamp$", description="Sort column (timestamp only)"),
    as_of: int | None = Query(None, ge=1, description="Rows up to this id: as_of of the first page"),
):
    """Paginated audit log with filtering and ordering. Superadmin only.

    Reading the log is written to it, after the query: the row holds the
    query. The pages of one query send back the as_of of its first page,
    so the rows written meanwhile shift none of them.
    """
    db = request.state.db
    result = db.get_audit_logs_paginated(
        page=page, limit=limit, action=action, username=username, ip=ip,
        order=order, sort_by=sort_by, as_of=as_of,
    )
    query = {"page": page, "limit": limit, "order": order, "action": action,
             "username": username, "ip": ip, "as_of": as_of}
    audit_log(
        db, request, "audit_viewed",
        actor=request.state.actor,
        detail={key: value for key, value in query.items() if value is not None},
    )
    return ApiOk(data=AuditLogPage(**result))
