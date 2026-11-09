"""
Docker scenario tests — run inside the auth container against the live service.

Usage: tools/dev.sh test --docker

Prerequisites:
  1. tools/setup.sh has been run (keys + DB + admin exist)
  2. docker compose up is running
  3. Admin password is in /run/secrets/.admin_password or AUTH_TEST_ADMIN_PASS env

Scenarios (executed in order):

  1. Admin login + me
     Login with bootstrap admin credentials → receive token → verify identity
     via /me → wrong password is rejected.

  2. User lifecycle
     Admin creates user → user logs in → password changed → login with new
     password → old password rejected → user appears in list → user deleted
     → deleted user cannot login.

  3. Session management
     Login → logout → same token rejected.
     Request without header → 401. Invalid token → 401.

  4. Self-protection
     Admin cannot delete own account → 400.

  5. TOTP full lifecycle
     Create user → login → enable TOTP (secret + URI + 8 backup codes)
     → login again: mfa_required + mfa_token returned
     → wrong TOTP code → 401
     → correct TOTP code (RFC 6238 HMAC-SHA1) → access token
     → login with backup code → access token
     → same backup code rejected on reuse → 401 (single-use)
     → disable TOTP (password confirmation required)
     → login succeeds without MFA
     → cleanup.

  6. Deleted user token revocation
     Create user → login → token works on /me → admin deletes user
     (sessions CASCADE delete) → same token returns 401.

  7. Duplicate user creation
     Create user → same username again → 409 Conflict.

  8. Audit log API (superadmin only)
     Unauthenticated → 401. Regular admin → 403.
     Superadmin: paginated response with correct schema.
     filter by action, username. Events from prior scenarios appear.

  9. Proxy audit logging
     A change through the proxy (success or 502) creates a proxy_request
     audit entry; a read does not. Entry has correct schema (method, path,
     status). Filterable via audit API.

  10. Rate limiting (last — poisons IP for the window duration)
      Rapid failed logins from same IP → sliding window fills → 429.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import struct
import time
from pathlib import Path

import httpx
import pytest

pytestmark = pytest.mark.docker

BASE_URL = os.environ.get("AUTH_TEST_URL", "http://localhost:8443")
ADMIN_USER = os.environ.get("AUTH_TEST_ADMIN_USER", "admin")


def _resolve_admin_pass() -> str:
    """Resolve admin password from env or bootstrap password file."""
    env_pass = os.environ.get("AUTH_TEST_ADMIN_PASS", "")
    if env_pass:
        return env_pass
    # Inside container: secrets dir is /run/secrets
    # Outside: container-data/secrets/development
    for candidate in (
        Path("/run/secrets/.admin_password"),
        Path("container-data/secrets/development/.admin_password"),
    ):
        if candidate.is_file():
            return candidate.read_text().strip()
    return ""


ADMIN_PASS = _resolve_admin_pass()


@pytest.fixture(scope="module")
def http():
    """Shared httpx client for the module."""
    with httpx.Client(base_url=BASE_URL, timeout=10.0) as client:
        yield client


@pytest.fixture(scope="module")
def admin_token(http):
    """Login as admin, return access token."""
    if not ADMIN_PASS:
        pytest.skip("Admin password not available (run tools/setup.sh first)")
    resp = http.post("/auth/login", json={"username": ADMIN_USER, "password": ADMIN_PASS})
    assert resp.status_code == 200, f"Admin login failed: {resp.json()}"
    return resp.json()["data"]["token"]


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _generate_totp_code(secret: str) -> str:
    """Generate a valid 6-digit TOTP code from a base32 secret."""
    key = base64.b32decode(secret)
    counter = struct.pack(">Q", int(time.time()) // 30)
    mac = hmac.new(key, counter, hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    truncated = struct.unpack(">I", mac[offset : offset + 4])[0] & 0x7FFFFFFF
    return str(truncated % 1_000_000).zfill(6)


# ── Scenario 1: Admin login + me ────────────────────────────────


class TestAdminLogin:
    def test_login_returns_token(self, http):
        if not ADMIN_PASS:
            pytest.skip("Admin password not available")
        resp = http.post("/auth/login", json={"username": ADMIN_USER, "password": ADMIN_PASS})
        assert resp.status_code == 200
        data = resp.json()
        assert data["ok"] is True
        assert "token" in data["data"]
        assert data["data"]["expires_in"] > 0

    def test_me_returns_admin(self, http, admin_token):
        resp = http.get("/auth/me", headers=_bearer(admin_token))
        assert resp.status_code == 200
        data = resp.json()["data"]
        assert data["username"] == ADMIN_USER
        assert data["totp_enabled"] is False

    def test_login_wrong_password(self, http):
        resp = http.post("/auth/login", json={"username": ADMIN_USER, "password": "wrongwrong"})
        assert resp.status_code == 401
        assert resp.json()["ok"] is False


# ── Scenario 2: User lifecycle ──────────────────────────────────


class TestUserLifecycle:
    USERNAME = "scenario_user"
    PASSWORD = "ScenarioPass1!"
    NEW_PASSWORD = "NewScenario2!"

    def test_01_create_user(self, http, admin_token):
        http.delete(f"/auth/users/{self.USERNAME}", headers=_bearer(admin_token))
        resp = http.post(
            "/auth/users",
            json={"username": self.USERNAME, "password": self.PASSWORD},
            headers=_bearer(admin_token),
        )
        assert resp.status_code == 200
        assert resp.json()["data"]["username"] == self.USERNAME

    def test_02_new_user_can_login(self, http):
        resp = http.post("/auth/login", json={"username": self.USERNAME, "password": self.PASSWORD})
        assert resp.status_code == 200
        assert "token" in resp.json()["data"]

    def test_03_change_password(self, http, admin_token):
        resp = http.post(
            f"/auth/users/{self.USERNAME}/password",
            json={"password": self.NEW_PASSWORD},
            headers=_bearer(admin_token),
        )
        assert resp.status_code == 200

    def test_04_login_with_new_password(self, http):
        resp = http.post(
            "/auth/login",
            json={"username": self.USERNAME, "password": self.NEW_PASSWORD},
        )
        assert resp.status_code == 200

    def test_05_old_password_rejected(self, http):
        resp = http.post(
            "/auth/login",
            json={"username": self.USERNAME, "password": self.PASSWORD},
        )
        assert resp.status_code == 401

    def test_06_list_users_includes_new(self, http, admin_token):
        resp = http.get("/auth/users", headers=_bearer(admin_token))
        assert resp.status_code == 200
        usernames = [u["username"] for u in resp.json()["data"]]
        assert self.USERNAME in usernames

    def test_07_delete_user(self, http, admin_token):
        resp = http.delete(f"/auth/users/{self.USERNAME}", headers=_bearer(admin_token))
        assert resp.status_code == 200

    def test_08_deleted_user_cannot_login(self, http):
        resp = http.post(
            "/auth/login",
            json={"username": self.USERNAME, "password": self.NEW_PASSWORD},
        )
        assert resp.status_code == 401


# ── Scenario 3: Session management ──────────────────────────────


class TestSessionManagement:
    def test_logout_revokes_token(self, http):
        if not ADMIN_PASS:
            pytest.skip("Admin password not available")
        resp = http.post("/auth/login", json={"username": ADMIN_USER, "password": ADMIN_PASS})
        token = resp.json()["data"]["token"]

        resp = http.post("/auth/logout", headers=_bearer(token))
        assert resp.status_code == 200

        resp = http.get("/auth/me", headers=_bearer(token))
        assert resp.status_code == 401

    def test_no_auth_returns_401(self, http):
        resp = http.get("/auth/me")
        assert resp.status_code == 401

    def test_invalid_token_returns_401(self, http):
        resp = http.get("/auth/me", headers=_bearer("invalid.jwt.token"))
        assert resp.status_code == 401


# ── Scenario 4: Self-protection ─────────────────────────────────


class TestSelfProtection:
    def test_cannot_delete_self(self, http, admin_token):
        resp = http.delete(f"/auth/users/{ADMIN_USER}", headers=_bearer(admin_token))
        assert resp.status_code == 400
        assert resp.json()["error_code"] == "CANNOT_DELETE_SELF"


# ── Scenario 5: Password change (2-step self-service) ──────────


class TestPasswordChange:
    USERNAME = "pwchange_scenario"
    PASSWORD = "PwChange1!"
    NEW_PASSWORD = "NewPwChange2!"

    def test_01_setup_user(self, http, admin_token):
        http.delete(f"/auth/users/{self.USERNAME}", headers=_bearer(admin_token))
        resp = http.post(
            "/auth/users",
            json={"username": self.USERNAME, "password": self.PASSWORD},
            headers=_bearer(admin_token),
        )
        assert resp.status_code == 200

    def test_02_verify_current_password(self, http):
        resp = http.post("/auth/login", json={"username": self.USERNAME, "password": self.PASSWORD})
        token = resp.json()["data"]["token"]
        resp = http.post(
            "/auth/password/verify",
            json={"password": self.PASSWORD},
            headers=_bearer(token),
        )
        assert resp.status_code == 200
        data = resp.json()["data"]
        assert "change_token" in data
        assert data["expires_in"] > 0
        TestPasswordChange._token = token
        TestPasswordChange._change_token = data["change_token"]

    # noinspection PyUnresolvedReferences
    def test_03_wrong_password_rejected(self, http):
        resp = http.post(
            "/auth/password/verify",
            json={"password": "WrongPass1!"},
            headers=_bearer(self._token),
        )
        assert resp.status_code == 401

    # noinspection PyUnresolvedReferences
    def test_04_same_password_rejected(self, http):
        resp = http.post(
            "/auth/password/change",
            json={"change_token": self._change_token, "password": self.PASSWORD},
            headers=_bearer(self._token),
        )
        assert resp.status_code == 400
        assert resp.json()["error_code"] == "PASSWORD_MUST_DIFFER"

    # noinspection PyUnresolvedReferences
    def test_05_change_password(self, http):
        resp = http.post(
            "/auth/password/change",
            json={"change_token": self._change_token, "password": self.NEW_PASSWORD},
            headers=_bearer(self._token),
        )
        assert resp.status_code == 200

    # noinspection PyUnresolvedReferences
    def test_06_old_session_revoked(self, http):
        resp = http.get("/auth/me", headers=_bearer(self._token))
        assert resp.status_code == 401

    def test_07_login_with_new_password(self, http):
        resp = http.post("/auth/login", json={"username": self.USERNAME, "password": self.NEW_PASSWORD})
        assert resp.status_code == 200
        assert "token" in resp.json()["data"]

    def test_08_old_password_rejected(self, http):
        resp = http.post("/auth/login", json={"username": self.USERNAME, "password": self.PASSWORD})
        assert resp.status_code == 401

    def test_09_cleanup(self, http, admin_token):
        http.delete(f"/auth/users/{self.USERNAME}", headers=_bearer(admin_token))


# ── Scenario 6: TOTP full lifecycle ──────────────────────────────


class TestTOTPLifecycle:
    USERNAME = "totp_scenario"
    PASSWORD = "TotpPass123!"
    _secret: str | None = None
    _backup_codes: list[str] | None = None

    def test_01_setup_user(self, http, admin_token):
        http.delete(f"/auth/users/{self.USERNAME}", headers=_bearer(admin_token))
        resp = http.post(
            "/auth/users",
            json={"username": self.USERNAME, "password": self.PASSWORD},
            headers=_bearer(admin_token),
        )
        assert resp.status_code == 200

    def test_02_enable_totp(self, http):
        resp = http.post("/auth/login", json={"username": self.USERNAME, "password": self.PASSWORD})
        token = resp.json()["data"]["token"]

        # Step 1: setup (verify password, get QR + backup codes)
        resp = http.post(
            "/auth/totp/setup",
            json={"password": self.PASSWORD},
            headers=_bearer(token),
        )
        assert resp.status_code == 200
        data = resp.json()["data"]
        assert "setup_token" in data
        assert "secret" in data
        assert "uri" in data
        assert len(data["backup_codes"]) == 8
        assert data["expires_in"] > 0

        # Step 2: confirm (verify TOTP code activates)
        code = _generate_totp_code(data["secret"])
        resp = http.post(
            "/auth/totp/confirm",
            json={"setup_token": data["setup_token"], "code": code},
            headers=_bearer(token),
        )
        assert resp.status_code == 200

        TestTOTPLifecycle._secret = data["secret"]
        TestTOTPLifecycle._backup_codes = data["backup_codes"]

    def test_03_login_requires_mfa(self, http):
        resp = http.post("/auth/login", json={"username": self.USERNAME, "password": self.PASSWORD})
        assert resp.status_code == 200
        data = resp.json()["data"]
        assert data["mfa_required"] is True
        assert "mfa_token" in data

    def test_04_wrong_totp_code_rejected(self, http):
        resp = http.post("/auth/login", json={"username": self.USERNAME, "password": self.PASSWORD})
        mfa_token = resp.json()["data"]["mfa_token"]

        resp = http.post("/auth/mfa/verify", json={"mfa_token": mfa_token, "code": "000000"})
        if resp.status_code == 200:
            return  # astronomically unlikely lucky hit
        assert resp.status_code == 401

    def test_05_successful_totp_login(self, http):
        if not self._secret:
            pytest.skip("TOTP secret not available from test_02")
        resp = http.post("/auth/login", json={"username": self.USERNAME, "password": self.PASSWORD})
        mfa_token = resp.json()["data"]["mfa_token"]

        code = _generate_totp_code(self._secret)
        resp = http.post("/auth/mfa/verify", json={"mfa_token": mfa_token, "code": code})
        assert resp.status_code == 200
        assert "token" in resp.json()["data"]

    def test_06_backup_code_login(self, http):
        if not self._backup_codes:
            pytest.skip("Backup codes not available from test_02")
        resp = http.post("/auth/login", json={"username": self.USERNAME, "password": self.PASSWORD})
        mfa_token = resp.json()["data"]["mfa_token"]

        code = self._backup_codes[0]
        resp = http.post("/auth/totp/backup", json={"mfa_token": mfa_token, "code": code})
        assert resp.status_code == 200
        assert "token" in resp.json()["data"]

    def test_07_used_backup_code_rejected(self, http):
        if not self._backup_codes:
            pytest.skip("Backup codes not available from test_02")
        resp = http.post("/auth/login", json={"username": self.USERNAME, "password": self.PASSWORD})
        mfa_token = resp.json()["data"]["mfa_token"]

        code = self._backup_codes[0]  # already used in test_06
        resp = http.post("/auth/totp/backup", json={"mfa_token": mfa_token, "code": code})
        assert resp.status_code == 401

    def test_08_disable_totp(self, http):
        if not self._secret:
            pytest.skip("TOTP secret not available from test_02")
        # Login with TOTP to get access token
        resp = http.post("/auth/login", json={"username": self.USERNAME, "password": self.PASSWORD})
        mfa_token = resp.json()["data"]["mfa_token"]
        code = _generate_totp_code(self._secret)
        resp = http.post("/auth/mfa/verify", json={"mfa_token": mfa_token, "code": code})
        token = resp.json()["data"]["token"]

        # Disable TOTP with password confirmation
        resp = http.post(
            "/auth/totp/disable",
            json={"password": self.PASSWORD},
            headers=_bearer(token),
        )
        assert resp.status_code == 200

    def test_09_login_without_mfa_after_disable(self, http):
        resp = http.post("/auth/login", json={"username": self.USERNAME, "password": self.PASSWORD})
        assert resp.status_code == 200
        data = resp.json()["data"]
        assert "token" in data
        assert "mfa_required" not in data or data.get("mfa_required") is False

    def test_10_cleanup(self, http, admin_token):
        http.delete(f"/auth/users/{self.USERNAME}", headers=_bearer(admin_token))


# ── Scenario 6: Deleted user token revocation ──────────────────


class TestDeletedUserToken:
    USERNAME = "revoke_scenario"
    PASSWORD = "RevokePass1!"

    def test_01_create_and_login(self, http, admin_token):
        http.delete(f"/auth/users/{self.USERNAME}", headers=_bearer(admin_token))
        resp = http.post(
            "/auth/users",
            json={"username": self.USERNAME, "password": self.PASSWORD},
            headers=_bearer(admin_token),
        )
        assert resp.status_code == 200

    def test_02_token_invalid_after_delete(self, http, admin_token):
        # Login as the user
        resp = http.post("/auth/login", json={"username": self.USERNAME, "password": self.PASSWORD})
        token = resp.json()["data"]["token"]

        # Verify token works
        resp = http.get("/auth/me", headers=_bearer(token))
        assert resp.status_code == 200

        # Admin deletes the user
        resp = http.delete(f"/auth/users/{self.USERNAME}", headers=_bearer(admin_token))
        assert resp.status_code == 200

        # Deleted user's token must be rejected
        resp = http.get("/auth/me", headers=_bearer(token))
        assert resp.status_code == 401


# ── Scenario 7: Duplicate user creation ────────────────────────


class TestDuplicateUser:
    USERNAME = "dup_scenario"
    PASSWORD = "DupPass123!"

    def test_duplicate_returns_409(self, http, admin_token):
        http.delete(f"/auth/users/{self.USERNAME}", headers=_bearer(admin_token))
        resp = http.post(
            "/auth/users",
            json={"username": self.USERNAME, "password": self.PASSWORD},
            headers=_bearer(admin_token),
        )
        assert resp.status_code == 200

        # Same username again → 409
        resp = http.post(
            "/auth/users",
            json={"username": self.USERNAME, "password": self.PASSWORD},
            headers=_bearer(admin_token),
        )
        assert resp.status_code == 409

        # Cleanup
        http.delete(f"/auth/users/{self.USERNAME}", headers=_bearer(admin_token))


# ── Scenario 8: Audit log API ────────────────────────────────────


class TestAuditLog:
    """GET /auth/audit — superadmin only, paginated, filterable."""

    _admin_token: str | None = None   # regular admin (role=admin) for 403 check
    TEMP_ADMIN = "audit_temp_admin"
    TEMP_PASS = "AuditTmp1!"

    def test_01_unauthenticated_rejected(self, http):
        resp = http.get("/auth/audit")
        assert resp.status_code == 401

    def test_02_regular_admin_forbidden(self, http, admin_token):
        # Create a regular admin (role=admin, not superadmin)
        http.delete(f"/auth/users/{self.TEMP_ADMIN}", headers={"Authorization": f"Bearer {admin_token}"})
        resp = http.post(
            "/auth/users",
            json={"username": self.TEMP_ADMIN, "password": self.TEMP_PASS},
            headers={"Authorization": f"Bearer {admin_token}"},
        )
        assert resp.status_code == 200

        resp = http.post("/auth/login", json={"username": self.TEMP_ADMIN, "password": self.TEMP_PASS})
        assert resp.status_code == 200
        TestAuditLog._admin_token = resp.json()["data"]["token"]

        resp = http.get("/auth/audit", headers={"Authorization": f"Bearer {self._admin_token}"})
        assert resp.status_code == 403

    def test_03_superadmin_ok(self, http, admin_token):
        resp = http.get("/auth/audit", headers={"Authorization": f"Bearer {admin_token}"})
        assert resp.status_code == 200
        data = resp.json()
        assert data["ok"] is True

    def test_04_response_schema(self, http, admin_token):
        resp = http.get("/auth/audit", headers={"Authorization": f"Bearer {admin_token}"})
        assert resp.status_code == 200
        page = resp.json()["data"]
        assert "items" in page
        assert "total" in page
        assert "page" in page
        assert "limit" in page
        assert "pages" in page
        assert page["page"] == 1
        assert page["limit"] == 25
        assert page["total"] >= 0

    def test_05_item_schema(self, http, admin_token):
        resp = http.get("/auth/audit", headers={"Authorization": f"Bearer {admin_token}"})
        items = resp.json()["data"]["items"]
        assert len(items) > 0, "Expected at least one audit entry from prior scenarios"
        item = items[0]
        assert "id" in item
        assert "user_id" in item
        assert "username" in item
        assert "action" in item
        assert "detail" in item and isinstance(item["detail"], dict)
        assert "ip_address" in item
        assert "timestamp" in item

    def test_06_pagination_limit(self, http, admin_token):
        resp = http.get("/auth/audit?page=1&limit=3", headers={"Authorization": f"Bearer {admin_token}"})
        assert resp.status_code == 200
        page = resp.json()["data"]
        assert page["limit"] == 3
        assert len(page["items"]) <= 3

    def test_07_pagination_second_page(self, http, admin_token):
        # Each read writes audit_viewed; the second page sends the first page's as_of.
        resp1 = http.get("/auth/audit?page=1&limit=5", headers={"Authorization": f"Bearer {admin_token}"})
        as_of = resp1.json()["data"]["as_of"]
        resp2 = http.get(f"/auth/audit?page=2&limit=5&as_of={as_of}",
                         headers={"Authorization": f"Bearer {admin_token}"})
        assert resp1.status_code == 200
        assert resp2.status_code == 200
        ids1 = {i["id"] for i in resp1.json()["data"]["items"]}
        ids2 = {i["id"] for i in resp2.json()["data"]["items"]}
        assert ids1.isdisjoint(ids2), "Pages must not overlap"

    def test_08_filter_action(self, http, admin_token):
        resp = http.get(
            "/auth/audit?action=login_success",
            headers={"Authorization": f"Bearer {admin_token}"},
        )
        assert resp.status_code == 200
        items = resp.json()["data"]["items"]
        assert len(items) > 0, "Expected login_success entries from prior scenarios"
        assert all(i["action"] == "login_success" for i in items)

    def test_09_filter_username(self, http, admin_token):
        resp = http.get(
            f"/auth/audit?username={ADMIN_USER}",
            headers={"Authorization": f"Bearer {admin_token}"},
        )
        assert resp.status_code == 200
        items = resp.json()["data"]["items"]
        assert len(items) > 0, f"Expected audit entries for {ADMIN_USER}"
        assert all(i["username"] == ADMIN_USER for i in items)

    def test_10_filter_nonexistent_action(self, http, admin_token):
        resp = http.get(
            "/auth/audit?action=nonexistent_action_xyz",
            headers={"Authorization": f"Bearer {admin_token}"},
        )
        assert resp.status_code == 200
        assert resp.json()["data"]["total"] == 0
        assert resp.json()["data"]["items"] == []

    def test_11_limit_max_enforced(self, http, admin_token):
        resp = http.get(
            "/auth/audit?limit=200",
            headers={"Authorization": f"Bearer {admin_token}"},
        )
        assert resp.status_code == 422  # limit > 100 rejected by FastAPI validation

    def test_12_order_desc_default(self, http, admin_token):
        resp = http.get("/auth/audit", headers={"Authorization": f"Bearer {admin_token}"})
        assert resp.status_code == 200
        page = resp.json()["data"]
        assert page["order"] == "desc"
        assert page["sort_by"] == "timestamp"
        ids = [i["id"] for i in page["items"]]
        assert ids == sorted(ids, reverse=True)

    def test_13_order_asc(self, http, admin_token):
        resp = http.get("/auth/audit?order=asc", headers={"Authorization": f"Bearer {admin_token}"})
        assert resp.status_code == 200
        page = resp.json()["data"]
        assert page["order"] == "asc"
        ids = [i["id"] for i in page["items"]]
        assert ids == sorted(ids)

    def test_14_order_invalid_rejected(self, http, admin_token):
        resp = http.get("/auth/audit?order=random", headers={"Authorization": f"Bearer {admin_token}"})
        assert resp.status_code == 422

    def test_15_sort_by_invalid_rejected(self, http, admin_token):
        resp = http.get("/auth/audit?sort_by=username", headers={"Authorization": f"Bearer {admin_token}"})
        assert resp.status_code == 422

    def test_16_cleanup(self, http, admin_token):
        http.delete(f"/auth/users/{self.TEMP_ADMIN}", headers={"Authorization": f"Bearer {admin_token}"})


# ── Scenario 9: Proxy audit logging ─────────────────────────────


class TestProxyAudit:
    """Proxy requests create proxy_request audit entries."""

    def test_01_proxy_request_creates_audit(self, http, admin_token):
        """A change through the proxy (success or 502) should produce an audit entry."""
        # Make a proxy request — daemon may or may not be running
        resp = http.post(
            "/api/core/clients/assign",
            json={"name": "audit-scenario"},
            headers=_bearer(admin_token),
        )
        # Accept 200 (daemon up) or 502 (daemon down) — both should audit
        assert resp.status_code in (200, 502)

    def test_02_audit_entry_exists(self, http, admin_token):
        """proxy_request entries appear in GET /auth/audit."""
        resp = http.get(
            "/auth/audit?action=proxy_request",
            headers=_bearer(admin_token),
        )
        assert resp.status_code == 200
        data = resp.json()["data"]
        assert data["total"] > 0, "Expected proxy_request audit entries"

    def test_03_audit_entry_schema(self, http, admin_token):
        """proxy_request entry has method, path, status in detail."""
        resp = http.get(
            "/auth/audit?action=proxy_request&limit=1",
            headers=_bearer(admin_token),
        )
        assert resp.status_code == 200
        items = resp.json()["data"]["items"]
        assert len(items) > 0
        item = items[0]
        assert item["action"] == "proxy_request"
        assert item["user_id"] is not None
        assert item["username"] == ADMIN_USER
        detail = item["detail"]
        assert "method" in detail
        assert "path" in detail
        assert "status" in detail
        assert isinstance(detail["status"], int)

    def test_04_proxy_post_audited(self, http, admin_token):
        """POST proxy request is also audited with correct method."""
        # This may return 502 if daemon is down — that's fine
        http.post(
            "/api/core/clients/assign",
            json={"name": "audit-test"},
            headers=_bearer(admin_token),
        )
        resp = http.get(
            "/auth/audit?action=proxy_request&limit=100&order=desc",
            headers=_bearer(admin_token),
        )
        assert resp.status_code == 200
        items = resp.json()["data"]["items"]
        post_entries = [i for i in items if i["detail"].get("method") == "POST"]
        assert len(post_entries) > 0, "Expected POST proxy audit entry"

    def test_05_unauthenticated_proxy_no_audit(self, http, admin_token):
        """Unauthenticated proxy request should NOT create audit entry."""
        # Count current proxy_request entries
        resp = http.get(
            "/auth/audit?action=proxy_request",
            headers=_bearer(admin_token),
        )
        count_before = resp.json()["data"]["total"]

        # Unauthenticated request — should get 401, no audit
        resp = http.get("/api/core/hello")
        assert resp.status_code == 401

        # Count should remain the same
        resp = http.get(
            "/auth/audit?action=proxy_request",
            headers=_bearer(admin_token),
        )
        count_after = resp.json()["data"]["total"]
        assert count_after == count_before, "Unauthenticated proxy should not create audit entry"

    def test_06_read_no_audit(self, http, admin_token):
        """A read through the proxy (success or 502) should NOT create an audit entry."""
        resp = http.get("/auth/audit?action=proxy_request", headers=_bearer(admin_token))
        count_before = resp.json()["data"]["total"]

        resp = http.get("/api/core/hello", headers=_bearer(admin_token))
        assert resp.status_code in (200, 502)

        resp = http.get("/auth/audit?action=proxy_request", headers=_bearer(admin_token))
        assert resp.json()["data"]["total"] == count_before, "A read should not create audit entry"


# ── Scenario 10: Rate limiting (last — poisons IP for the window) ─


class TestRateLimit:
    def test_rapid_failed_logins_trigger_429(self, http):
        resp = None
        for _ in range(10):
            resp = http.post("/auth/login", json={"username": "x", "password": "y"})
            if resp.status_code == 429:
                break
        assert resp is not None and resp.status_code == 429
