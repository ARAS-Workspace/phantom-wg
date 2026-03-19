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

FastAPI auth dependency — Bearer extraction, JWT verify, inactivity check.
"""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import Request

from auth_service.crypto.jwt import TokenPayload, decode_token, token_hash
from auth_service.errors import ApiException, AuthTokenExpiredError, AuthTokenInvalidError


def require_auth(request: Request) -> TokenPayload:
    """Extract and verify Bearer token. Check session validity and inactivity."""
    auth_header = request.headers.get("authorization", "")
    if not auth_header.startswith("Bearer "):
        raise ApiException(401, "MISSING_AUTH_HEADER")

    raw_token = auth_header[7:]
    verify_key = request.app.state.verify_key
    config = request.app.state.config
    db = request.state.db

    try:
        payload = decode_token(verify_key, raw_token)
    except AuthTokenExpiredError:
        raise ApiException(401, "TOKEN_EXPIRED")
    except AuthTokenInvalidError:
        raise ApiException(401, "TOKEN_INVALID")

    if payload.typ != "access":
        raise ApiException(401, "INVALID_TOKEN_TYPE")

    session = db.get_session_by_jti(payload.jti)
    if session is None or session.revoked:
        raise ApiException(401, "SESSION_REVOKED")

    # Verify token hash matches stored hash
    if token_hash(raw_token) != session.token_hash:
        raise ApiException(401, "TOKEN_MISMATCH")

    # Inactivity timeout check
    last_activity = datetime.fromisoformat(session.last_activity_at)
    now = datetime.now(timezone.utc)
    elapsed = (now - last_activity).total_seconds()
    if elapsed > config.inactivity_timeout:
        db.revoke_session(payload.jti)
        raise ApiException(401, "SESSION_INACTIVE")

    # Update last activity
    db.update_last_activity(payload.jti)

    return payload


def require_superadmin(request: Request) -> TokenPayload:
    """Require authenticated superadmin user."""
    payload = require_auth(request)
    if payload.role != "superadmin":
        raise ApiException(403, "SUPERADMIN_REQUIRED")
    return payload
