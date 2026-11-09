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

from auth_service.audit import account, audit_log, get_client_ip, log_refused_login
from auth_service.crypto.jwt import TokenPayload, decode_token, encode_token
from auth_service.crypto.password import verify_password
from auth_service.crypto.totp import hash_backup_code, verify_totp
from auth_service.errors import (
    ApiException,
    AuthTokenExpiredError,
    AuthTokenInvalidError,
)
from auth_service.models import (
    ApiOk,
    LoginRequest,
    MFARequiredResponse,
    MFAVerifyRequest,
)
from auth_service.routes.auth._helpers import issue_access_token

router = APIRouter()


# ── Login ────────────────────────────────────────────────────────


@router.post("/login")
def login(body: LoginRequest, request: Request):
    """Authenticate with username+password. Returns JWT or MFA challenge."""
    db = request.state.db
    rate_limiter = request.app.state.rate_limiter
    ip = get_client_ip(request)

    # A refused login has no verified identity: service log, no audit row.
    if not rate_limiter.check(ip):
        log_refused_login(request, "login_rate_limited", body.username)
        raise ApiException(429, "RATE_LIMITED")

    user = db.get_user_by_username(body.username)
    if user is None or not verify_password(body.password, user.password_hash):
        log_refused_login(request, "login_failed", body.username)
        raise ApiException(401, "INVALID_CREDENTIALS")

    # No limiter reset here: with TOTP enabled the password alone is not
    # authentication, and resetting now would hand an attacker who knows
    # the password an unlimited TOTP budget. issue_access_token resets.

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
        audit_log(db, request, "mfa_challenge", actor=account(user.id, user.username))
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

    # A 6-digit TOTP is brute-forceable without this; same budget as login.
    # Refused before the MFA token is read: no identity, service log only.
    if not request.app.state.rate_limiter.check(get_client_ip(request)):
        log_refused_login(request, "mfa_rate_limited")
        raise ApiException(429, "RATE_LIMITED")

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
        audit_log(db, request, "mfa_failed", actor=account(user.id, user.username))
        raise ApiException(401, "INVALID_TOTP_CODE")

    audit_log(db, request, "mfa_success", actor=account(user.id, user.username))
    return issue_access_token(request, user.username, user.id, user.role)


# ── MFA Backup Code ─────────────────────────────────────────────


@router.post("/totp/backup")
def mfa_backup(body: MFAVerifyRequest, request: Request):
    """Verify backup code and issue access token."""
    db = request.state.db

    # Backup codes are single-use but guessable without a budget.
    # Refused before the MFA token is read: no identity, service log only.
    if not request.app.state.rate_limiter.check(get_client_ip(request)):
        log_refused_login(request, "backup_code_rate_limited")
        raise ApiException(429, "RATE_LIMITED")

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
        audit_log(db, request, "backup_code_failed", actor=account(user.id, user.username))
        raise ApiException(401, "INVALID_BACKUP_CODE")

    remaining = db.count_remaining_backup_codes(user.id)
    audit_log(
        db, request, "backup_code_used",
        actor=account(user.id, user.username),
        detail={"remaining": remaining},
    )
    return issue_access_token(request, user.username, user.id, user.role)


# ── Helper ───────────────────────────────────────────────────────


def _decode_mfa_token(verify_key: VerifyKey, mfa_token: str) -> TokenPayload:
    """Decode and validate an MFA pending token."""
    payload = decode_token(verify_key, mfa_token)
    if payload.typ != "mfa_pending":
        raise AuthTokenInvalidError("Invalid MFA token type")
    return payload
