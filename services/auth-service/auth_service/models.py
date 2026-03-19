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

Pydantic request/response models.
"""

from __future__ import annotations

import re
from typing import Generic, Literal, TypeVar

from pydantic import BaseModel, Field, field_validator

T = TypeVar("T")

# Password policy: min 8 chars, at least 1 uppercase, 1 lowercase, 1 digit, 1 special
PASSWORD_PATTERN = re.compile(
    r"^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[!@#$%^&*()_+\-=\[\]{}|;:'\",.<>?/`~\\])"
    r".{8,256}$"
)
PASSWORD_POLICY_MESSAGE = (
    "Password must be 8-256 characters with at least 1 uppercase, "
    "1 lowercase, 1 digit, and 1 special character"
)


def _validate_password(v: str) -> str:
    if not PASSWORD_PATTERN.match(v):
        raise ValueError(PASSWORD_POLICY_MESSAGE)
    return v


# ── Envelope ─────────────────────────────────────────────────────


class ApiOk(BaseModel, Generic[T]):
    ok: Literal[True] = True
    data: T


class ApiErr(BaseModel):
    ok: Literal[False] = False
    error_code: str


class ActionResult(BaseModel):
    """Success response for action endpoints that return no domain data."""
    success_code: str


# ── Auth Requests ────────────────────────────────────────────────


class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=256)


class CreateUserRequest(BaseModel):
    username: str = Field(min_length=1, max_length=64, pattern=r"^[a-zA-Z0-9_\-]+$")
    password: str = Field(min_length=8, max_length=256)

    @field_validator("password")
    @classmethod
    def password_strength(cls, v: str) -> str:
        return _validate_password(v)


class ChangePasswordRequest(BaseModel):
    password: str = Field(min_length=8, max_length=256)

    @field_validator("password")
    @classmethod
    def password_strength(cls, v: str) -> str:
        return _validate_password(v)


class PasswordVerifyRequest(BaseModel):
    password: str = Field(min_length=1, max_length=256)


class PasswordChangeRequest(BaseModel):
    change_token: str
    password: str = Field(min_length=8, max_length=256)

    @field_validator("password")
    @classmethod
    def password_strength(cls, v: str) -> str:
        return _validate_password(v)


class PasswordVerifyResponse(BaseModel):
    change_token: str
    expires_in: int


class MFAVerifyRequest(BaseModel):
    mfa_token: str
    code: str = Field(min_length=6, max_length=8)


class TOTPSetupRequest(BaseModel):
    password: str = Field(min_length=1, max_length=256)


class TOTPConfirmRequest(BaseModel):
    setup_token: str
    code: str = Field(min_length=6, max_length=6)


class TOTPDisableRequest(BaseModel):
    password: str = Field(min_length=1, max_length=256)
    username: str | None = None


# ── Auth Responses ───────────────────────────────────────────────


class LoginResponse(BaseModel):
    token: str
    expires_in: int


class MFARequiredResponse(BaseModel):
    mfa_required: Literal[True] = True
    mfa_token: str
    expires_in: int


class UserInfo(BaseModel):
    id: str
    username: str
    role: str
    totp_enabled: bool
    created_at: str
    updated_at: str


class TOTPSetupResponse(BaseModel):
    setup_token: str
    secret: str
    uri: str
    backup_codes: list[str]
    expires_in: int


# ── Audit Log ─────────────────────────────────────────────────────


class AuditLogEntry(BaseModel):
    id: int
    user_id: str | None
    username: str | None
    action: str
    detail: dict
    ip_address: str
    timestamp: str


class AuditLogPage(BaseModel):
    items: list[AuditLogEntry]
    total: int
    page: int
    limit: int
    pages: int
    order: str
    sort_by: str
