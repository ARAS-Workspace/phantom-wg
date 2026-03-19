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

Self-service password change — two-step verify/change flow.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, Request

from auth_service.audit import audit_log
from auth_service.crypto.jwt import TokenPayload, decode_token_claims, encode_token
from auth_service.crypto.password import hash_password, verify_password
from auth_service.errors import ApiException, AuthTokenExpiredError, AuthTokenInvalidError
from auth_service.middleware.auth import require_auth
from auth_service.models import (
    ActionResult,
    ApiOk,
    PasswordChangeRequest,
    PasswordVerifyRequest,
    PasswordVerifyResponse,
)

router = APIRouter()


@router.post("/password/verify")
def password_verify(
    body: PasswordVerifyRequest,
    request: Request,
    payload: TokenPayload = Depends(require_auth),
):
    """Step 1: Verify current password → issue short-lived change token."""
    db = request.state.db
    config = request.app.state.config
    signing_key = request.app.state.signing_key

    user = db.get_user_by_username(payload.sub)
    if user is None:
        raise ApiException(404, "USER_NOT_FOUND")
    if not verify_password(body.password, user.password_hash):
        raise ApiException(401, "INVALID_PASSWORD")

    change_token = encode_token(
        signing_key=signing_key,
        sub=user.username,
        jti=uuid.uuid4().hex,
        lifetime=config.mfa_token_lifetime,
        typ="password_change",
    )

    audit_log(db, request, "password_change_started", {"username": user.username}, user_id=user.id)
    return ApiOk(data=PasswordVerifyResponse(
        change_token=change_token,
        expires_in=config.mfa_token_lifetime,
    ))


@router.post("/password/change")
def password_change(
    body: PasswordChangeRequest,
    request: Request,
    payload: TokenPayload = Depends(require_auth),
):
    """Step 2: Change password using verified change token."""
    db = request.state.db

    try:
        claims = decode_token_claims(request.app.state.verify_key, body.change_token)
    except AuthTokenExpiredError:
        raise ApiException(401, "TOKEN_EXPIRED")
    except AuthTokenInvalidError:
        raise ApiException(401, "TOKEN_INVALID")

    if claims.get("typ") != "password_change":
        raise ApiException(401, "INVALID_CHANGE_TOKEN")
    if claims.get("sub") != payload.sub:
        raise ApiException(401, "TOKEN_SUBJECT_MISMATCH")

    user = db.get_user_by_username(payload.sub)
    if user is None:
        raise ApiException(404, "USER_NOT_FOUND")
    if verify_password(body.password, user.password_hash):
        raise ApiException(400, "PASSWORD_MUST_DIFFER")

    db.update_password(payload.sub, hash_password(body.password))
    db.revoke_user_sessions(user.id)

    audit_log(db, request, "password_changed", {"username": payload.sub, "by": payload.sub})
    return ApiOk(data=ActionResult(success_code="PASSWORD_CHANGED"))
