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

Shared helpers for auth route modules.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

from fastapi import Request

from auth_service.audit import audit_log
from auth_service.crypto.jwt import encode_token, token_hash
from auth_service.models import ApiOk, LoginResponse, UserInfo


def issue_access_token(request: Request, username: str, user_id: str, role: str = "admin") -> ApiOk:
    """Create session + issue access JWT."""
    config = request.app.state.config
    signing_key = request.app.state.signing_key
    db = request.state.db

    jti = uuid.uuid4().hex
    token = encode_token(
        signing_key=signing_key,
        sub=username,
        jti=jti,
        lifetime=config.token_lifetime,
        extra={"role": role},
    )

    now = datetime.now(timezone.utc)
    expires = now + timedelta(seconds=config.token_lifetime)
    db.create_session(
        user_id=user_id,
        token_jti=jti,
        token_hash=token_hash(token),
        issued_at=now.isoformat(),
        expires_at=expires.isoformat(),
    )

    audit_log(db, request, "login_success", {"username": username}, user_id=user_id)
    return ApiOk(data=LoginResponse(token=token, expires_in=config.token_lifetime))


def user_info(user) -> UserInfo:
    return UserInfo(
        id=user.id,
        username=user.username,
        role=user.role,
        totp_enabled=user.totp_secret is not None,
        created_at=user.created_at,
        updated_at=user.updated_at,
    )


def get_client_ip(request: Request) -> str:
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    if request.client:
        return request.client.host
    return ""
