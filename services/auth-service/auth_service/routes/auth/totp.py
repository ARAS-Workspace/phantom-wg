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

TOTP setup, confirm, and disable endpoints.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, Request

from auth_service.audit import audit_log
from auth_service.crypto.jwt import TokenPayload, decode_token_claims, encode_token
from auth_service.crypto.password import verify_password
from auth_service.crypto.totp import (
    build_totp_uri,
    generate_backup_codes,
    generate_secret,
    hash_backup_code,
    verify_totp,
)
from auth_service.errors import ApiException, AuthTokenExpiredError, AuthTokenInvalidError
from auth_service.middleware.auth import require_auth
from auth_service.models import (
    ActionResult,
    ApiOk,
    TOTPConfirmRequest,
    TOTPDisableRequest,
    TOTPSetupRequest,
    TOTPSetupResponse,
)

router = APIRouter()


# ── TOTP Setup ───────────────────────────────────────────────────


@router.post("/totp/setup")
def totp_setup(
    body: TOTPSetupRequest,
    request: Request,
    payload: TokenPayload = Depends(require_auth),
):
    """Start TOTP setup. Verify password, return setup token with secret and backup codes."""
    db = request.state.db
    config = request.app.state.config
    signing_key = request.app.state.signing_key

    user = db.get_user_by_username(payload.sub)
    if user is None:
        raise ApiException(404, "USER_NOT_FOUND")
    if user.totp_secret is not None:
        raise ApiException(409, "TOTP_ALREADY_ENABLED")
    if not verify_password(body.password, user.password_hash):
        raise ApiException(401, "INVALID_PASSWORD")

    secret = generate_secret()
    uri = build_totp_uri(secret, user.username)
    backup_codes = generate_backup_codes()

    setup_token = encode_token(
        signing_key=signing_key,
        sub=user.username,
        jti=uuid.uuid4().hex,
        lifetime=config.totp_setup_lifetime,
        typ="totp_setup",
        extra={"totp_secret": secret, "backup_codes": backup_codes},
    )

    audit_log(db, request, "totp_setup_started", {"username": user.username}, user_id=user.id)
    return ApiOk(data=TOTPSetupResponse(
        setup_token=setup_token,
        secret=secret,
        uri=uri,
        backup_codes=backup_codes,
        expires_in=config.totp_setup_lifetime,
    ))


# ── TOTP Confirm ─────────────────────────────────────────────────


@router.post("/totp/confirm")
def totp_confirm(
    body: TOTPConfirmRequest,
    request: Request,
    payload: TokenPayload = Depends(require_auth),
):
    """Confirm TOTP setup by verifying a code. Activates TOTP on success."""
    db = request.state.db

    try:
        claims = decode_token_claims(request.app.state.verify_key, body.setup_token)
    except AuthTokenExpiredError:
        raise ApiException(401, "TOKEN_EXPIRED")
    except AuthTokenInvalidError:
        raise ApiException(401, "TOKEN_INVALID")

    if claims.get("typ") != "totp_setup":
        raise ApiException(401, "INVALID_SETUP_TOKEN")
    if claims.get("sub") != payload.sub:
        raise ApiException(401, "TOKEN_SUBJECT_MISMATCH")

    totp_secret = claims.get("totp_secret")
    backup_codes = claims.get("backup_codes")
    if not totp_secret or not backup_codes:
        raise ApiException(401, "INVALID_SETUP_CLAIMS")

    user = db.get_user_by_username(payload.sub)
    if user is None:
        raise ApiException(404, "USER_NOT_FOUND")
    if user.totp_secret is not None:
        raise ApiException(409, "TOTP_ALREADY_ENABLED")
    if not verify_totp(totp_secret, body.code):
        raise ApiException(401, "INVALID_TOTP_CODE")

    backup_hashes = [hash_backup_code(c) for c in backup_codes]
    db.set_totp_secret(user.id, totp_secret)
    db.store_backup_codes(user.id, backup_hashes)

    audit_log(db, request, "totp_enabled", {"username": user.username}, user_id=user.id)
    return ApiOk(data=ActionResult(success_code="TOTP_ENABLED"))


# ── TOTP Disable ─────────────────────────────────────────────────


@router.post("/totp/disable")
def totp_disable(
    body: TOTPDisableRequest,
    request: Request,
    payload: TokenPayload = Depends(require_auth),
):
    """Disable TOTP. Self: own password. Superadmin: any user with own password."""
    db = request.state.db

    target_username = body.username or payload.sub
    if target_username != payload.sub and payload.role != "superadmin":
        raise ApiException(403, "CANNOT_DISABLE_OTHERS_TOTP")

    caller = db.get_user_by_username(payload.sub)
    if caller is None:
        raise ApiException(404, "USER_NOT_FOUND")
    if not verify_password(body.password, caller.password_hash):
        raise ApiException(401, "INVALID_PASSWORD")

    target = db.get_user_by_username(target_username) if target_username != payload.sub else caller
    if target is None:
        raise ApiException(404, "USER_NOT_FOUND")
    if target.totp_secret is None:
        raise ApiException(400, "TOTP_NOT_ENABLED")

    db.set_totp_secret(target.id, None)
    db.clear_backup_codes(target.id)

    audit_log(
        db, request, "totp_disabled",
        {"username": target.username, "by": payload.sub},
        user_id=target.id,
    )
    return ApiOk(data=ActionResult(success_code="TOTP_DISABLED"))
