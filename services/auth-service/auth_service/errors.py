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

Auth service error hierarchy.
"""

from __future__ import annotations

from fastapi import HTTPException


class AuthError(Exception):
    """Base error for auth service."""


class AuthSecretsError(AuthError):
    """Key loading / validation failures."""


class AuthDatabaseError(AuthError):
    """Database operation failures."""


class AuthTokenError(AuthError):
    """Base class for JWT encode / decode / validation failures."""


class AuthTokenExpiredError(AuthTokenError):
    """Token has passed its expiration time."""


class AuthTokenInvalidError(AuthTokenError):
    """Token is malformed, has an invalid signature, or contains unexpected claims."""


class AuthCredentialsError(AuthError):
    """Login credential failures."""


class AuthRateLimitError(AuthError):
    """Rate limit exceeded."""


class AuthMFARequiredError(AuthError):
    """TOTP verification required to complete login."""


class AuthMFAError(AuthError):
    """TOTP setup / verification failures."""


class AuthInactivityError(AuthError):
    """Session expired due to inactivity."""


# ── API error code mechanism ─────────────────────────────────────


class ApiException(HTTPException):
    """API error with machine-readable error_code for frontend i18n.

    Response contains only ``error_code`` — no English strings.
    The frontend maps error_code to the active locale's message.
    """

    def __init__(self, status_code: int, code: str) -> None:
        super().__init__(status_code=status_code, detail=code)
        self.error_code = code
