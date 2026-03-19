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

Login, MFA verify, and backup code endpoints.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Request
from nacl.signing import VerifyKey

from auth_service.audit import audit_log
from auth_service.crypto.jwt import TokenPayload, decode_token, encode_token
from auth_service.crypto.password import verify_password
from auth_service.crypto.totp import hash_backup_code, verify_totp
from auth_service.errors import ApiException, AuthTokenExpiredError, AuthTokenInvalidError
from auth_service.models import ApiOk, MFARequiredResponse, MFAVerifyRequest, LoginRequest
from auth_service.routes.auth._helpers import get_client_ip, issue_access_token

router = APIRouter()


# ── Login ────────────────────────────────────────────────────────


@router.post("/login")
def login(body: LoginRequest, request: Request):
    """Authenticate with username+password. Returns JWT or MFA challenge."""
    db = request.state.db
    rate_limiter = request.app.state.rate_limiter
    ip = get_client_ip(request)

    if not rate_limiter.check(ip):
        audit_log(db, request, "login_rate_limited", {"username": body.username})
        raise ApiException(429, "RATE_LIMITED")

    user = db.get_user_by_username(body.username)
    if user is None or not verify_password(body.password, user.password_hash):
        audit_log(db, request, "login_failed", {"username": body.username})
        raise ApiException(401, "INVALID_CREDENTIALS")

    rate_limiter.reset(ip)

    # TOTP enabled → issue short-lived MFA pending token
    if user.totp_secret is not None:
        config = request.app.state.config
        signing_key = request.app.state.signing_key
        mfa_token = encode_token(
            signing_key=signing_key,
            sub=user.username,
            jti=uuid.uuid4().hex,
            lifetime=config.mfa_token_lifetime,
            typ="mfa_pending",
        )
        audit_log(db, request, "mfa_challenge", {"username": user.username}, user_id=user.id)
        return ApiOk(data=MFARequiredResponse(
            mfa_token=mfa_token,
            expires_in=config.mfa_token_lifetime,
        ))

    return issue_access_token(request, user.username, user.id, user.role)


# ── MFA Verify ───────────────────────────────────────────────────


@router.post("/mfa/verify")
def mfa_verify(body: MFAVerifyRequest, request: Request):
    """Verify TOTP code and issue access token."""
    db = request.state.db

    try:
        payload = _decode_mfa_token(request.app.state.verify_key, body.mfa_token)
    except AuthTokenExpiredError:
        raise ApiException(401, "TOKEN_EXPIRED")
    except AuthTokenInvalidError:
        raise ApiException(401, "TOKEN_INVALID")

    user = db.get_user_by_username(payload.sub)
    if user is None or user.totp_secret is None:
        raise ApiException(401, "INVALID_MFA_STATE")

    if not verify_totp(user.totp_secret, body.code):
        audit_log(db, request, "mfa_failed", {"username": user.username}, user_id=user.id)
        raise ApiException(401, "INVALID_TOTP_CODE")

    audit_log(db, request, "mfa_success", {"username": user.username}, user_id=user.id)
    return issue_access_token(request, user.username, user.id, user.role)


# ── MFA Backup Code ─────────────────────────────────────────────


@router.post("/totp/backup")
def mfa_backup(body: MFAVerifyRequest, request: Request):
    """Verify backup code and issue access token."""
    db = request.state.db

    try:
        payload = _decode_mfa_token(request.app.state.verify_key, body.mfa_token)
    except AuthTokenExpiredError:
        raise ApiException(401, "TOKEN_EXPIRED")
    except AuthTokenInvalidError:
        raise ApiException(401, "TOKEN_INVALID")

    user = db.get_user_by_username(payload.sub)
    if user is None or user.totp_secret is None:
        raise ApiException(401, "INVALID_MFA_STATE")

    code_hash = hash_backup_code(body.code)
    if not db.verify_backup_code(user.id, code_hash):
        audit_log(db, request, "backup_code_failed", {"username": user.username}, user_id=user.id)
        raise ApiException(401, "INVALID_BACKUP_CODE")

    remaining = db.count_remaining_backup_codes(user.id)
    audit_log(
        db, request, "backup_code_used",
        {"username": user.username, "remaining": remaining},
        user_id=user.id,
    )
    return issue_access_token(request, user.username, user.id, user.role)


# ── Helper ───────────────────────────────────────────────────────


def _decode_mfa_token(verify_key: VerifyKey, mfa_token: str) -> TokenPayload:
    """Decode and validate an MFA pending token."""
    payload = decode_token(verify_key, mfa_token)
    if payload.typ != "mfa_pending":
        raise AuthTokenInvalidError("Invalid MFA token type")
    return payload
