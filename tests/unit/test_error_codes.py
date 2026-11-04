"""
Unit tests for error code infrastructure:
ApiException, AuthToken* hierarchy, ActionResult, ApiErr.
"""

from __future__ import annotations

import pytest

from auth_service.errors import (
    ApiException,
    AuthTokenError,
    AuthTokenExpiredError,
    AuthTokenInvalidError,
)
from auth_service.models import ActionResult, ApiErr

# ── ApiException ─────────────────────────────────────────────────


def test_api_exception_sets_status_and_code():
    exc = ApiException(401, "INVALID_CREDENTIALS")
    assert exc.status_code == 401
    assert exc.error_code == "INVALID_CREDENTIALS"


def test_api_exception_detail_equals_code():
    exc = ApiException(403, "SUPERADMIN_REQUIRED")
    assert exc.detail == "SUPERADMIN_REQUIRED"


def test_api_exception_is_http_exception():
    from fastapi import HTTPException
    exc = ApiException(404, "USER_NOT_FOUND")
    assert isinstance(exc, HTTPException)


def test_api_exception_all_defined_codes():
    codes = [
        (429, "RATE_LIMITED"),
        (401, "INVALID_CREDENTIALS"),
        (401, "INVALID_MFA_STATE"),
        (401, "INVALID_TOTP_CODE"),
        (401, "INVALID_BACKUP_CODE"),
        (409, "TOTP_ALREADY_ENABLED"),
        (400, "TOTP_NOT_ENABLED"),
        (403, "CANNOT_DISABLE_OTHERS_TOTP"),
        (401, "INVALID_SETUP_TOKEN"),
        (401, "INVALID_SETUP_CLAIMS"),
        (401, "INVALID_PASSWORD"),
        (401, "INVALID_CHANGE_TOKEN"),
        (400, "PASSWORD_MUST_DIFFER"),
        (403, "CANNOT_CHANGE_OTHERS_PASSWORD"),
        (404, "USER_NOT_FOUND"),
        (409, "USER_ALREADY_EXISTS"),
        (400, "CANNOT_DELETE_SELF"),
        (403, "SUPERADMIN_REQUIRED"),
        (401, "MISSING_AUTH_HEADER"),
        (401, "INVALID_TOKEN_TYPE"),
        (401, "SESSION_REVOKED"),
        (401, "TOKEN_MISMATCH"),
        (401, "TOKEN_SUBJECT_MISMATCH"),
        (401, "SESSION_INACTIVE"),
        (401, "TOKEN_EXPIRED"),
        (401, "TOKEN_INVALID"),
        (413, "BODY_TOO_LARGE"),
        (502, "SERVICE_UNAVAILABLE"),
    ]
    for status, code in codes:
        exc = ApiException(status, code)
        assert exc.status_code == status
        assert exc.error_code == code


# ── AuthToken hierarchy ──────────────────────────────────────────


def test_expired_is_subclass_of_token_error():
    assert issubclass(AuthTokenExpiredError, AuthTokenError)


def test_invalid_is_subclass_of_token_error():
    assert issubclass(AuthTokenInvalidError, AuthTokenError)


def test_expired_caught_as_base():
    with pytest.raises(AuthTokenError):
        raise AuthTokenExpiredError("expired")


def test_invalid_caught_as_base():
    with pytest.raises(AuthTokenError):
        raise AuthTokenInvalidError("bad sig")


def test_expired_not_caught_as_invalid():
    with pytest.raises(AuthTokenExpiredError):
        try:
            raise AuthTokenExpiredError("expired")
        except AuthTokenInvalidError:
            pass  # should NOT be caught here


def test_ordered_except_resolves_expired_first():
    """Simulate the pattern used in routes — expired must match before base."""
    def _handle(exc: AuthTokenError) -> str:
        try:
            raise exc
        except AuthTokenExpiredError:
            return "TOKEN_EXPIRED"
        except AuthTokenInvalidError:
            return "TOKEN_INVALID"

    assert _handle(AuthTokenExpiredError("exp")) == "TOKEN_EXPIRED"
    assert _handle(AuthTokenInvalidError("bad")) == "TOKEN_INVALID"


# ── Models ───────────────────────────────────────────────────────


def test_api_err_has_error_code_field():
    err = ApiErr(error_code="SESSION_REVOKED")
    assert err.ok is False
    assert err.error_code == "SESSION_REVOKED"
    assert not hasattr(err, "error") or "error" not in err.model_fields


def test_api_err_has_no_message_field():
    assert "message" not in ApiErr.model_fields
    assert "error" not in ApiErr.model_fields


def test_action_result_has_success_code():
    result = ActionResult(success_code="LOGGED_OUT")
    assert result.success_code == "LOGGED_OUT"


def test_action_result_known_codes():
    for code in ("LOGGED_OUT", "PASSWORD_CHANGED", "TOTP_ENABLED", "TOTP_DISABLED", "USER_DELETED"):
        r = ActionResult(success_code=code)
        assert r.success_code == code
