"""
Integration tests for error_code and success_code response contracts.

Verifies that:
- Every error response contains "error_code", never "error"
- Every action success response contains "data.success_code", never "data.message"
- Specific codes are returned for specific conditions
- Generic fallback codes are emitted by the global handler (422 → VALIDATION_ERROR)
"""

from __future__ import annotations

from auth_service.crypto.totp import generate_secret
from auth_service.middleware.rate_limit import RateLimiter

# ── Helpers ───────────────────────────────────────────────────────


def _assert_error(resp, status: int, code: str) -> None:
    assert resp.status_code == status
    body = resp.json()
    assert body["ok"] is False
    assert body["error_code"] == code
    assert "error" not in body
    assert "message" not in body


def _assert_action(resp, code: str) -> None:
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body["data"]["success_code"] == code
    assert "message" not in body["data"]


# ── Authentication error codes ────────────────────────────────────


def test_invalid_credentials_code(auth_env):
    auth_env.create_user("u1", "pass1234")
    client = auth_env.make_client()
    resp = client.post("/auth/login", json={"username": "u1", "password": "wrong"})
    _assert_error(resp, 401, "INVALID_CREDENTIALS")


def test_rate_limited_code(auth_env):
    client = auth_env.make_client(rate_limiter=RateLimiter(window=60, max_attempts=1))
    client.post("/auth/login", json={"username": "x", "password": "y"})
    resp = client.post("/auth/login", json={"username": "x", "password": "y"})
    _assert_error(resp, 429, "RATE_LIMITED")


def test_invalid_totp_code_code(auth_env):
    user = auth_env.create_user("totpuser", "totppass1")
    auth_env.db.set_totp_secret(user.id, generate_secret())
    client = auth_env.make_client()
    resp = client.post("/auth/login", json={"username": "totpuser", "password": "totppass1"})
    mfa_token = resp.json()["data"]["mfa_token"]
    resp = client.post("/auth/mfa/verify", json={"mfa_token": mfa_token, "code": "000000"})
    _assert_error(resp, 401, "INVALID_TOTP_CODE")


def test_invalid_backup_code_code(auth_env):
    user = auth_env.create_user("backupuser", "backuppass1")
    auth_env.db.set_totp_secret(user.id, generate_secret())
    client = auth_env.make_client()
    resp = client.post("/auth/login", json={"username": "backupuser", "password": "backuppass1"})
    mfa_token = resp.json()["data"]["mfa_token"]
    resp = client.post("/auth/totp/backup", json={"mfa_token": mfa_token, "code": "wrong1"})
    _assert_error(resp, 401, "INVALID_BACKUP_CODE")


# ── Token & session error codes ───────────────────────────────────


def test_missing_auth_header_code(auth_env):
    client = auth_env.make_client()
    resp = client.get("/auth/me")
    _assert_error(resp, 401, "MISSING_AUTH_HEADER")


def test_token_invalid_code(auth_env):
    client = auth_env.make_client()
    resp = client.get("/auth/me", headers={"Authorization": "Bearer not.a.token"})
    _assert_error(resp, 401, "TOKEN_INVALID")


def test_token_expired_code(auth_env):
    import time

    from auth_service.crypto.jwt import encode_token
    auth_env.create_user("expuser", "exppass12")
    token = encode_token(auth_env.signing_key, sub="expuser", jti="t1", lifetime=1)
    time.sleep(2)
    client = auth_env.make_client()
    resp = client.get("/auth/me", headers=auth_env.bearer(token))
    _assert_error(resp, 401, "TOKEN_EXPIRED")


def test_session_revoked_code(auth_env):
    auth_env.create_user("revuser", "revpass12")
    token = auth_env.issue_token("revuser")
    from auth_service.crypto.jwt import decode_token
    payload = decode_token(auth_env.verify_key, token)
    auth_env.db.revoke_session(payload.jti)
    client = auth_env.make_client()
    resp = client.get("/auth/me", headers=auth_env.bearer(token))
    _assert_error(resp, 401, "SESSION_REVOKED")


def test_superadmin_required_code(auth_env):
    auth_env.create_user("regadmin", "adminpw12")
    token = auth_env.login("regadmin", "adminpw12")
    client = auth_env.make_client()
    resp = client.get("/auth/users", headers=auth_env.bearer(token))
    _assert_error(resp, 403, "SUPERADMIN_REQUIRED")


# ── TOTP error codes ──────────────────────────────────────────────


def test_totp_already_enabled_code(auth_env):
    auth_env.create_user("totpdup", "totppass1")
    token = auth_env.login("totpdup", "totppass1")
    auth_env.enable_totp("totpdup", "totppass1", token)
    client = auth_env.make_client()
    resp = client.post("/auth/totp/setup", json={"password": "totppass1"}, headers=auth_env.bearer(token))
    _assert_error(resp, 409, "TOTP_ALREADY_ENABLED")


def test_totp_not_enabled_code(auth_env):
    auth_env.create_user("nototen", "notenpass1")
    token = auth_env.login("nototen", "notenpass1")
    client = auth_env.make_client()
    resp = client.post("/auth/totp/disable", json={"password": "notenpass1"}, headers=auth_env.bearer(token))
    _assert_error(resp, 400, "TOTP_NOT_ENABLED")


def test_cannot_disable_others_totp_code(auth_env):
    auth_env.create_user("admin1", "adminpw12")
    auth_env.create_user("target1", "targetpw1")
    t_token = auth_env.login("target1", "targetpw1")
    auth_env.enable_totp("target1", "targetpw1", t_token)
    a_token = auth_env.login("admin1", "adminpw12")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/totp/disable",
        json={"password": "adminpw12", "username": "target1"},
        headers=auth_env.bearer(a_token),
    )
    _assert_error(resp, 403, "CANNOT_DISABLE_OTHERS_TOTP")


# ── Password error codes ──────────────────────────────────────────


def test_invalid_password_code(auth_env):
    auth_env.create_user("pwtest", "pwtest123")
    token = auth_env.login("pwtest", "pwtest123")
    client = auth_env.make_client()
    resp = client.post("/auth/password/verify", json={"password": "wrongpass"}, headers=auth_env.bearer(token))
    _assert_error(resp, 401, "INVALID_PASSWORD")


def test_password_must_differ_code(auth_env):
    auth_env.create_user("pwsame", "OldPw1234!")
    token = auth_env.login("pwsame", "OldPw1234!")
    client = auth_env.make_client()
    resp = client.post("/auth/password/verify", json={"password": "OldPw1234!"}, headers=auth_env.bearer(token))
    change_token = resp.json()["data"]["change_token"]
    resp = client.post(
        "/auth/password/change",
        json={"change_token": change_token, "password": "OldPw1234!"},
        headers=auth_env.bearer(token),
    )
    _assert_error(resp, 400, "PASSWORD_MUST_DIFFER")


def test_cannot_change_others_password_code(auth_env):
    auth_env.create_user("admin2", "adminpw12")
    auth_env.create_user("other2", "otherpw123")
    token = auth_env.login("admin2", "adminpw12")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/users/other2/password",
        json={"password": "Hacked1234!"},
        headers=auth_env.bearer(token),
    )
    _assert_error(resp, 403, "CANNOT_CHANGE_OTHERS_PASSWORD")


# ── User management error codes ───────────────────────────────────


def test_user_not_found_code(auth_env):
    auth_env.create_user("sadmin", "SAdminPw1!", role="superadmin")
    token = auth_env.login("sadmin", "SAdminPw1!")
    client = auth_env.make_client()
    resp = client.delete("/auth/users/nonexistent", headers=auth_env.bearer(token))
    _assert_error(resp, 404, "USER_NOT_FOUND")


def test_user_already_exists_code(auth_env):
    auth_env.create_user("sadmin2", "SAdm2Pw1!", role="superadmin")
    auth_env.create_user("dup", "DupPw1234!")
    token = auth_env.login("sadmin2", "SAdm2Pw1!")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/users",
        json={"username": "dup", "password": "DupPw1234!"},
        headers=auth_env.bearer(token),
    )
    _assert_error(resp, 409, "USER_ALREADY_EXISTS")


def test_cannot_delete_self_code(auth_env):
    auth_env.create_user("sadmin3", "SAdm3Pw1!", role="superadmin")
    token = auth_env.login("sadmin3", "SAdm3Pw1!")
    client = auth_env.make_client()
    resp = client.delete("/auth/users/sadmin3", headers=auth_env.bearer(token))
    _assert_error(resp, 400, "CANNOT_DELETE_SELF")


# ── Validation fallback ───────────────────────────────────────────


def test_validation_error_code(auth_env):
    client = auth_env.make_client()
    # Missing required field → 422
    resp = client.post("/auth/login", json={"username": "x"})
    _assert_error(resp, 422, "VALIDATION_ERROR")


def test_no_error_string_in_any_error_response(auth_env):
    """No error response should contain an 'error' or 'message' key."""
    client = auth_env.make_client()
    cases = [
        client.get("/auth/me"),
        client.post("/auth/login", json={"username": "x", "password": "y"}),
        client.post("/auth/login", json={}),
    ]
    for resp in cases:
        body = resp.json()
        assert body["ok"] is False
        assert "error" not in body
        assert "message" not in body
        assert "error_code" in body


# ── Success codes ─────────────────────────────────────────────────


def test_logout_success_code(auth_env):
    auth_env.create_user("logoutsc", "logoutpw1")
    token = auth_env.login("logoutsc", "logoutpw1")
    client = auth_env.make_client()
    resp = client.post("/auth/logout", headers=auth_env.bearer(token))
    _assert_action(resp, "LOGGED_OUT")


def test_password_changed_success_code(auth_env):
    auth_env.create_user("pwsc", "OldPwSc1!")
    token = auth_env.login("pwsc", "OldPwSc1!")
    client = auth_env.make_client()
    resp = client.post("/auth/password/verify", json={"password": "OldPwSc1!"}, headers=auth_env.bearer(token))
    change_token = resp.json()["data"]["change_token"]
    resp = client.post(
        "/auth/password/change",
        json={"change_token": change_token, "password": "NewPwSc1!"},
        headers=auth_env.bearer(token),
    )
    _assert_action(resp, "PASSWORD_CHANGED")


def test_totp_enabled_success_code(auth_env):
    auth_env.create_user("totpsc", "TotpSc12!")
    token = auth_env.login("totpsc", "TotpSc12!")
    client = auth_env.make_client()
    resp = client.post("/auth/totp/setup", json={"password": "TotpSc12!"}, headers=auth_env.bearer(token))
    setup_data = resp.json()["data"]

    import base64
    import hashlib
    import hmac
    import struct
    import time
    key = base64.b32decode(setup_data["secret"])
    counter = struct.pack(">Q", int(time.time()) // 30)
    mac = hmac.new(key, counter, hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    code = str((struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000).zfill(6)

    resp = client.post(
        "/auth/totp/confirm",
        json={"setup_token": setup_data["setup_token"], "code": code},
        headers=auth_env.bearer(token),
    )
    _assert_action(resp, "TOTP_ENABLED")


def test_totp_disabled_success_code(auth_env):
    auth_env.create_user("totpdsc", "TotpDs12!")
    token = auth_env.login("totpdsc", "TotpDs12!")
    auth_env.enable_totp("totpdsc", "TotpDs12!", token)
    client = auth_env.make_client()
    resp = client.post("/auth/totp/disable", json={"password": "TotpDs12!"}, headers=auth_env.bearer(token))
    _assert_action(resp, "TOTP_DISABLED")


def test_user_deleted_success_code(auth_env):
    auth_env.create_user("sadmin4", "SAdm4Pw1!", role="superadmin")
    auth_env.create_user("todel", "ToDel1234!")
    token = auth_env.login("sadmin4", "SAdm4Pw1!")
    client = auth_env.make_client()
    resp = client.delete("/auth/users/todel", headers=auth_env.bearer(token))
    _assert_action(resp, "USER_DELETED")


def test_admin_password_changed_success_code(auth_env):
    auth_env.create_user("sadmin5", "SAdm5Pw1!", role="superadmin")
    auth_env.create_user("tochpw", "ToChPw1!")
    token = auth_env.login("sadmin5", "SAdm5Pw1!")
    client = auth_env.make_client()
    resp = client.post(
        "/auth/users/tochpw/password",
        json={"password": "Changed1!"},
        headers=auth_env.bearer(token),
    )
    _assert_action(resp, "PASSWORD_CHANGED")
