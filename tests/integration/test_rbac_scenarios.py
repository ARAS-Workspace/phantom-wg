"""
Docker RBAC scenario tests — role-based access control verification.

Usage: tools/dev.sh test --docker

Prerequisites:
  1. tools/setup.sh has been run (bootstrap superadmin exists)
  2. docker compose up is running
  3. Admin password in /run/secrets/.admin_password or AUTH_TEST_ADMIN_PASS env

Scenarios (executed in order):

  1. Superadmin creates admin user
     Bootstrap superadmin logs in → creates admin user → admin appears in list.

  2. Admin cannot manage users
     Admin logs in → cannot create user (403) → cannot list users (403)
     → cannot delete user (403).

  3. Admin can only change own password
     Admin changes own password → success.
     Admin changes superadmin's password → 403.

  4. Superadmin can change any password
     Superadmin changes admin's password → success.
     Admin logs in with new password → success.

  5. Admin TOTP: self-management only
     Admin enables own TOTP → login requires MFA → admin disables own TOTP.
     Admin cannot disable superadmin's TOTP → 403.

  6. Superadmin can disable other's TOTP
     Superadmin enables TOTP on admin → superadmin disables admin's TOTP
     with own password → success.

  7. Superadmin cannot delete self
     Superadmin tries to delete self → 400.

  8. Proxy access by role
     Admin is refused on backup, on the server configuration and on multihop
     beside its status (403), and keeps the reads and the client tunnels.
     Superadmin passes the role check on those routes. A path outside the
     route table is 404 for both, however it is spelled. Body limits hold per
     route. The service runs without a daemon here: a route that passes the
     checks answers 502.

  9. Superadmin deletes admin
     Superadmin deletes admin → admin token revoked → admin cannot login.

  10. Role in JWT and /me response
     Login returns role in /me → superadmin sees "superadmin",
     admin sees "admin".
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import struct
import time
from http.client import HTTPConnection
from pathlib import Path

import httpx
import pytest

pytestmark = pytest.mark.docker

BASE_URL = os.environ.get("AUTH_TEST_URL", "http://localhost:8443")
ADMIN_USER = os.environ.get("AUTH_TEST_ADMIN_USER", "admin")


def _resolve_admin_pass() -> str:
    env_pass = os.environ.get("AUTH_TEST_ADMIN_PASS", "")
    if env_pass:
        return env_pass
    for candidate in (
        Path("/run/secrets/.admin_password"),
        Path("container-data/secrets/development/.admin_password"),
    ):
        if candidate.is_file():
            return candidate.read_text().strip()
    return ""


ADMIN_PASS = _resolve_admin_pass()


def _bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _generate_totp_code(secret: str) -> str:
    key = base64.b32decode(secret)
    counter = struct.pack(">Q", int(time.time()) // 30)
    mac = hmac.new(key, counter, hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    truncated = struct.unpack(">I", mac[offset : offset + 4])[0] & 0x7FFFFFFF
    return str(truncated % 1_000_000).zfill(6)


def _enable_totp(http, token: str, password: str) -> str:
    """Full TOTP enable flow (setup + confirm). Returns secret."""
    resp = http.post("/auth/totp/setup", json={"password": password}, headers=_bearer(token))
    assert resp.status_code == 200, resp.json()
    data = resp.json()["data"]
    code = _generate_totp_code(data["secret"])
    resp2 = http.post(
        "/auth/totp/confirm",
        json={"setup_token": data["setup_token"], "code": code},
        headers=_bearer(token),
    )
    assert resp2.status_code == 200, resp2.json()
    return data["secret"]


@pytest.fixture(scope="module")
def http():
    with httpx.Client(base_url=BASE_URL, timeout=10.0) as client:
        yield client


@pytest.fixture(scope="module")
def superadmin_token(http):
    if not ADMIN_PASS:
        pytest.skip("Admin password not available")
    resp = http.post("/auth/login", json={"username": ADMIN_USER, "password": ADMIN_PASS})
    assert resp.status_code == 200, f"Superadmin login failed: {resp.json()}"
    return resp.json()["data"]["token"]


# ── Scenario 1: Superadmin creates admin ───────────────────────


class TestSuperadminCreatesAdmin:
    USERNAME = "rbac_admin"
    PASSWORD = "RbacAdmin1!"

    def test_01_create_admin(self, http, superadmin_token):
        http.delete(f"/auth/users/{self.USERNAME}", headers=_bearer(superadmin_token))
        resp = http.post(
            "/auth/users",
            json={"username": self.USERNAME, "password": self.PASSWORD},
            headers=_bearer(superadmin_token),
        )
        assert resp.status_code == 200
        data = resp.json()["data"]
        assert data["username"] == self.USERNAME
        assert data["role"] == "admin"

    def test_02_admin_in_user_list(self, http, superadmin_token):
        resp = http.get("/auth/users", headers=_bearer(superadmin_token))
        assert resp.status_code == 200
        usernames = [u["username"] for u in resp.json()["data"]]
        assert self.USERNAME in usernames


# ── Scenario 2: Admin cannot manage users ──────────────────────


class TestAdminCannotManageUsers:
    def test_01_admin_cannot_create(self, http):
        resp = http.post("/auth/login", json={
            "username": "rbac_admin", "password": "RbacAdmin1!",
        })
        assert resp.status_code == 200
        token = resp.json()["data"]["token"]
        resp = http.post(
            "/auth/users",
            json={"username": "blocked", "password": "Blocked123!"},
            headers=_bearer(token),
        )
        assert resp.status_code == 403

    def test_02_admin_cannot_list(self, http):
        resp = http.post("/auth/login", json={
            "username": "rbac_admin", "password": "RbacAdmin1!",
        })
        token = resp.json()["data"]["token"]
        resp = http.get("/auth/users", headers=_bearer(token))
        assert resp.status_code == 403

    def test_03_admin_cannot_delete(self, http):
        resp = http.post("/auth/login", json={
            "username": "rbac_admin", "password": "RbacAdmin1!",
        })
        token = resp.json()["data"]["token"]
        resp = http.delete(f"/auth/users/{ADMIN_USER}", headers=_bearer(token))
        assert resp.status_code == 403


# ── Scenario 3: Admin can only change own password ─────────────


class TestAdminPasswordScope:
    NEW_PASSWORD = "NewRbac12!"

    def test_01_admin_changes_own_password(self, http):
        resp = http.post("/auth/login", json={
            "username": "rbac_admin", "password": "RbacAdmin1!",
        })
        token = resp.json()["data"]["token"]
        resp = http.post(
            "/auth/users/rbac_admin/password",
            json={"password": self.NEW_PASSWORD},
            headers=_bearer(token),
        )
        assert resp.status_code == 200

    def test_02_admin_cannot_change_superadmin_password(self, http):
        resp = http.post("/auth/login", json={
            "username": "rbac_admin", "password": self.NEW_PASSWORD,
        })
        token = resp.json()["data"]["token"]
        resp = http.post(
            f"/auth/users/{ADMIN_USER}/password",
            json={"password": "Hacked1234!"},
            headers=_bearer(token),
        )
        assert resp.status_code == 403


# ── Scenario 4: Superadmin can change any password ─────────────


class TestSuperadminPasswordScope:
    RESET_PASSWORD = "ResetPw123!"

    def test_01_superadmin_changes_admin_password(self, http, superadmin_token):
        resp = http.post(
            "/auth/users/rbac_admin/password",
            json={"password": self.RESET_PASSWORD},
            headers=_bearer(superadmin_token),
        )
        assert resp.status_code == 200

    def test_02_admin_logs_in_with_new_password(self, http):
        resp = http.post("/auth/login", json={
            "username": "rbac_admin", "password": self.RESET_PASSWORD,
        })
        assert resp.status_code == 200
        assert "token" in resp.json()["data"]


# ── Scenario 5: Admin TOTP self-management ─────────────────────


class TestAdminTotpSelfManagement:
    _secret: str | None = None

    def test_01_admin_enables_own_totp(self, http):
        resp = http.post("/auth/login", json={
            "username": "rbac_admin", "password": "ResetPw123!",
        })
        token = resp.json()["data"]["token"]
        secret = _enable_totp(http, token, "ResetPw123!")
        TestAdminTotpSelfManagement._secret = secret

    def test_02_admin_login_requires_mfa(self, http):
        resp = http.post("/auth/login", json={
            "username": "rbac_admin", "password": "ResetPw123!",
        })
        assert resp.json()["data"]["mfa_required"] is True

    def test_03_admin_disables_own_totp(self, http):
        resp = http.post("/auth/login", json={
            "username": "rbac_admin", "password": "ResetPw123!",
        })
        mfa_token = resp.json()["data"]["mfa_token"]
        code = _generate_totp_code(self._secret)
        resp = http.post("/auth/mfa/verify", json={"mfa_token": mfa_token, "code": code})
        token = resp.json()["data"]["token"]
        resp = http.post(
            "/auth/totp/disable",
            json={"password": "ResetPw123!"},
            headers=_bearer(token),
        )
        assert resp.status_code == 200

    def test_04_admin_cannot_disable_superadmin_totp(self, http, superadmin_token):
        # Enable TOTP on superadmin
        secret = _enable_totp(http, superadmin_token, ADMIN_PASS)
        TestAdminTotpSelfManagement._sa_secret = secret
        # Admin tries to disable superadmin's TOTP
        resp = http.post("/auth/login", json={
            "username": "rbac_admin", "password": "ResetPw123!",
        })
        admin_token = resp.json()["data"]["token"]
        resp = http.post(
            "/auth/totp/disable",
            json={"password": "ResetPw123!", "username": ADMIN_USER},
            headers=_bearer(admin_token),
        )
        assert resp.status_code == 403

    def test_05_cleanup_superadmin_totp(self, http):
        # Superadmin disables own TOTP so later scenarios work
        resp = http.post("/auth/login", json={"username": ADMIN_USER, "password": ADMIN_PASS})
        mfa_token = resp.json()["data"]["mfa_token"]
        # noinspection PyUnresolvedReferences
        code = _generate_totp_code(self._sa_secret)
        resp = http.post("/auth/mfa/verify", json={"mfa_token": mfa_token, "code": code})
        token = resp.json()["data"]["token"]
        resp = http.post(
            "/auth/totp/disable",
            json={"password": ADMIN_PASS},
            headers=_bearer(token),
        )
        assert resp.status_code == 200


# ── Scenario 6: Superadmin disables other's TOTP ──────────────


class TestSuperadminDisablesOtherTotp:
    def test_01_enable_totp_on_admin(self, http):
        resp = http.post("/auth/login", json={
            "username": "rbac_admin", "password": "ResetPw123!",
        })
        token = resp.json()["data"]["token"]
        _enable_totp(http, token, "ResetPw123!")
        resp = http.get("/auth/me", headers=_bearer(token))
        assert resp.json()["data"]["totp_enabled"] is True

    def test_02_superadmin_disables_admin_totp(self, http, superadmin_token):
        resp = http.post(
            "/auth/totp/disable",
            json={"password": ADMIN_PASS, "username": "rbac_admin"},
            headers=_bearer(superadmin_token),
        )
        assert resp.status_code == 200


# ── Scenario 7: Superadmin cannot delete self ──────────────────


class TestSuperadminCannotDeleteSelf:
    def test_self_delete_rejected(self, http, superadmin_token):
        resp = http.delete(f"/auth/users/{ADMIN_USER}", headers=_bearer(superadmin_token))
        assert resp.status_code == 400
        assert resp.json()["error_code"] == "CANNOT_DELETE_SELF"


# ── Scenario 8: Proxy access by role ────────────────


def _status_on_the_wire(path: str, token: str) -> int:
    """POST with the path exactly as written; httpx normalizes dot segments."""
    url = httpx.URL(BASE_URL)
    conn = HTTPConnection(url.host, url.port, timeout=10)
    try:
        conn.request("POST", path, body=b"", headers=_bearer(token))
        return conn.getresponse().status
    finally:
        conn.close()


@pytest.fixture(scope="class")
def admin_token(http):
    resp = http.post("/auth/login", json={
        "username": "rbac_admin", "password": "ResetPw123!",
    })
    assert resp.status_code == 200
    return resp.json()["data"]["token"]


class TestProxyAccessByRole:
    BACKUP_ROUTES = ("/api/core/backup/export", "/api/core/backup/import")
    # A read, the pool check, the multihop status and the client tunnels.
    ADMIN_HOLDS = (
        ("GET", "/api/core/clients/list"),
        ("GET", "/api/core/network/validate"),
        ("GET", "/api/multihop/status"),
        ("POST", "/api/core/clients/assign"),
        ("POST", "/api/core/clients/revoke"),
    )
    # The address pool, DNS, and multihop beside its status.
    SUPERADMIN_HOLDS = (
        ("POST", "/api/core/network/cidr"),
        ("POST", "/api/dns/change"),
        ("GET", "/api/multihop/list"),
        ("POST", "/api/multihop/config"),
        ("POST", "/api/multihop/enable"),
    )
    # No daemon runs beside the service: 502 is a request that passed the checks.
    PASSED = (200, 502)
    OVER_THE_LIMIT = b"x" * 65537

    def test_01_admin_is_refused_on_backup(self, http, admin_token):
        for route in self.BACKUP_ROUTES:
            resp = http.post(route, headers=_bearer(admin_token))
            assert resp.status_code == 403
            assert resp.json()["error_code"] == "SUPERADMIN_REQUIRED"

    def test_02_superadmin_passes_on_backup(self, http, superadmin_token):
        for route in self.BACKUP_ROUTES:
            resp = http.post(route, headers=_bearer(superadmin_token))
            assert resp.status_code in self.PASSED

    def test_03_admin_keeps_the_reads_and_the_tunnels(self, http, admin_token):
        for method, route in self.ADMIN_HOLDS:
            resp = http.request(method, route, headers=_bearer(admin_token))
            assert resp.status_code in self.PASSED, route

    def test_04_route_outside_the_table_is_404(self, http, admin_token, superadmin_token):
        for token in (admin_token, superadmin_token):
            resp = http.post("/api/core/nonexistent", headers=_bearer(token))
            assert resp.status_code == 404
            assert resp.json()["error_code"] == "NOT_FOUND"

    def test_05_method_is_part_of_the_match(self, http, superadmin_token):
        resp = http.get("/api/core/backup/export", headers=_bearer(superadmin_token))
        assert resp.status_code == 404

    def test_06_decoded_spelling_is_the_route_itself(self, admin_token):
        assert _status_on_the_wire("/api/core/%62ackup/export", admin_token) == 403
        assert _status_on_the_wire("/api/core%2Fbackup%2Fexport", admin_token) == 403

    def test_07_other_spelling_is_not_a_route(self, superadmin_token):
        for path in (
            "/api/core/x/../backup/export",
            "/api/core/./backup/export",
            "/api/core/%2562ackup/export",
            "/api/core//backup/export",
            "/api/core/backup/export/",
        ):
            assert _status_on_the_wire(path, superadmin_token) == 404, path

    def test_08_body_limit_holds_on_the_other_routes(self, http, superadmin_token):
        resp = http.post(
            "/api/core/clients/assign",
            content=self.OVER_THE_LIMIT,
            headers=_bearer(superadmin_token),
        )
        assert resp.status_code == 413
        assert resp.json()["error_code"] == "BODY_TOO_LARGE"

    def test_09_backup_takes_the_large_body(self, http, superadmin_token):
        resp = http.post(
            "/api/core/backup/import",
            content=self.OVER_THE_LIMIT,
            headers=_bearer(superadmin_token),
        )
        assert resp.status_code != 413

    def test_10_refusal_is_in_the_audit_log(self, http, superadmin_token):
        resp = http.get(
            "/auth/audit?action=proxy_request&username=rbac_admin&limit=100",
            headers=_bearer(superadmin_token),
        )
        assert resp.status_code == 200
        refused = [
            item["detail"]["path"] for item in resp.json()["data"]["items"]
            if item["detail"]["status"] == 403
        ]
        assert "/api/core/backup/export" in refused

    def test_11_admin_is_refused_on_the_superadmin_routes(self, http, admin_token):
        for method, route in self.SUPERADMIN_HOLDS:
            resp = http.request(method, route, headers=_bearer(admin_token))
            assert resp.status_code == 403, route
            assert resp.json()["error_code"] == "SUPERADMIN_REQUIRED"

    def test_12_superadmin_passes_on_the_superadmin_routes(self, http, superadmin_token):
        for method, route in self.SUPERADMIN_HOLDS:
            resp = http.request(method, route, headers=_bearer(superadmin_token))
            assert resp.status_code in self.PASSED, route


# ── Scenario 9: Superadmin deletes admin ───────────────────────


class TestSuperadminDeletesAdmin:
    def test_01_delete_admin(self, http, superadmin_token):
        resp = http.delete("/auth/users/rbac_admin", headers=_bearer(superadmin_token))
        assert resp.status_code == 200

    def test_02_deleted_admin_cannot_login(self, http):
        resp = http.post("/auth/login", json={
            "username": "rbac_admin", "password": "ResetPw123!",
        })
        assert resp.status_code == 401


# ── Scenario 10: Role in /me response ──────────────────────────


class TestRoleInResponse:
    def test_superadmin_role(self, http, superadmin_token):
        resp = http.get("/auth/me", headers=_bearer(superadmin_token))
        assert resp.json()["data"]["role"] == "superadmin"

    def test_admin_role(self, http, superadmin_token):
        # Create fresh admin for this test
        http.delete("/auth/users/roletest", headers=_bearer(superadmin_token))
        http.post(
            "/auth/users",
            json={"username": "roletest", "password": "RoleTest1!"},
            headers=_bearer(superadmin_token),
        )
        resp = http.post("/auth/login", json={"username": "roletest", "password": "RoleTest1!"})
        token = resp.json()["data"]["token"]
        resp = http.get("/auth/me", headers=_bearer(token))
        assert resp.json()["data"]["role"] == "admin"
        # Cleanup
        http.delete("/auth/users/roletest", headers=_bearer(superadmin_token))
