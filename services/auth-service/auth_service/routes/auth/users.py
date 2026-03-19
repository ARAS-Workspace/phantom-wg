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

User management endpoints — superadmin only (except self password change).
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from auth_service.audit import audit_log
from auth_service.crypto.jwt import TokenPayload
from auth_service.crypto.password import hash_password
from auth_service.errors import ApiException, AuthDatabaseError
from auth_service.middleware.auth import require_auth, require_superadmin
from auth_service.models import ActionResult, ApiOk, ChangePasswordRequest, CreateUserRequest
from auth_service.routes.auth._helpers import user_info

router = APIRouter()


@router.post("/users")
def create_user(
    body: CreateUserRequest,
    request: Request,
    payload: TokenPayload = Depends(require_superadmin),
):
    """Create a new admin user. Superadmin only."""
    db = request.state.db
    try:
        user = db.create_user(
            username=body.username,
            password_hash=hash_password(body.password),
            role="admin",
        )
    except AuthDatabaseError:
        raise ApiException(409, "USER_ALREADY_EXISTS")
    audit_log(
        db, request, "user_created",
        {"username": body.username, "by": payload.sub},
        user_id=user.id,
    )
    return ApiOk(data=user_info(user))


@router.get("/users")
def list_users(
    request: Request,
    _payload: TokenPayload = Depends(require_superadmin),
):
    """List all users. Superadmin only."""
    db = request.state.db
    return ApiOk(data=[user_info(u) for u in db.list_users()])


@router.delete("/users/{username}")
def delete_user(
    username: str,
    request: Request,
    payload: TokenPayload = Depends(require_superadmin),
):
    """Delete a user. Superadmin only. Cannot delete self."""
    if username == payload.sub:
        raise ApiException(400, "CANNOT_DELETE_SELF")
    db = request.state.db
    user = db.get_user_by_username(username)
    if user is None:
        raise ApiException(404, "USER_NOT_FOUND")
    db.revoke_user_sessions(user.id)
    db.delete_user(username)
    audit_log(
        db, request, "user_deleted",
        {"username": username, "by": payload.sub},
        user_id=user.id,
    )
    return ApiOk(data=ActionResult(success_code="USER_DELETED"))


@router.post("/users/{username}/password")
def change_password(
    username: str,
    body: ChangePasswordRequest,
    request: Request,
    payload: TokenPayload = Depends(require_auth),
):
    """Change password. Superadmin: any user. Admin: only self."""
    if payload.role != "superadmin" and username != payload.sub:
        raise ApiException(403, "CANNOT_CHANGE_OTHERS_PASSWORD")
    db = request.state.db
    if not db.update_password(username, hash_password(body.password)):
        raise ApiException(404, "USER_NOT_FOUND")
    audit_log(
        db, request, "password_changed",
        {"username": username, "by": payload.sub},
    )
    return ApiOk(data=ActionResult(success_code="PASSWORD_CHANGED"))
