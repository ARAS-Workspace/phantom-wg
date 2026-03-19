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

Session management — logout and current user endpoints.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from auth_service.audit import audit_log
from auth_service.crypto.jwt import TokenPayload
from auth_service.errors import ApiException
from auth_service.middleware.auth import require_auth
from auth_service.models import ActionResult, ApiOk
from auth_service.routes.auth._helpers import user_info

router = APIRouter()


@router.post("/logout")
def logout(request: Request, payload: TokenPayload = Depends(require_auth)):
    """Revoke current session."""
    db = request.state.db
    db.revoke_session(payload.jti)
    audit_log(db, request, "logout", {"username": payload.sub})
    return ApiOk(data=ActionResult(success_code="LOGGED_OUT"))


@router.get("/me")
def me(request: Request, payload: TokenPayload = Depends(require_auth)):
    """Get current user info."""
    db = request.state.db
    user = db.get_user_by_username(payload.sub)
    if user is None:
        raise ApiException(404, "USER_NOT_FOUND")
    return ApiOk(data=user_info(user))
