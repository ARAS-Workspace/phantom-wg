"""Docker: tools/add_superadmin.py in the auth image, on the auth.db of the running service.

Runs inside the auth container, where tools/ is mounted read-only beside
auth_service/. The account the script adds logs in through the running
service at once: it opens a connection per request. The test removes the
account at the end.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import httpx
import pytest

pytestmark = pytest.mark.docker

BASE_URL = os.environ.get("AUTH_TEST_URL", "http://localhost:8443")
ADMIN_USER = os.environ.get("AUTH_TEST_ADMIN_USER", "admin")
DB_DIR = os.environ.get("AUTH_DB_DIR", "/var/lib/phantom/auth")
APP_DIR = "/app"
NAME = "e2e-host-root"
PASSWORD = "E2e-Host-Root-2026!"


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


def _add(username: str, stdin: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-m", "tools.add_superadmin", "--db-dir", DB_DIR, "--username", username],
        input=stdin, capture_output=True, text=True, cwd=APP_DIR, check=False,
    )


@pytest.fixture(scope="module")
def http():
    with httpx.Client(base_url=BASE_URL, timeout=10.0) as client:
        yield client


@pytest.fixture(scope="module")
def superadmin_token(http):
    if not ADMIN_PASS:
        pytest.skip("Admin password not available")
    resp = http.post("/auth/login", json={"username": ADMIN_USER, "password": ADMIN_PASS})
    assert resp.status_code == 200, resp.json()
    return resp.json()["data"]["token"]


class TestAddSuperadminInTheImage:
    def test_01_no_account_left_behind(self, http, superadmin_token):
        resp = http.delete(f"/auth/users/{NAME}", headers=_bearer(superadmin_token))
        assert resp.status_code in (200, 404)

    def test_02_the_password_comes_on_stdin(self):
        done = _add(NAME, PASSWORD + "\n")
        assert done.returncode == 0, done.stdout
        assert done.stdout == f"SUPERADMIN_CREATED={NAME}\n"
        assert PASSWORD not in done.stdout + done.stderr

    def test_03_the_running_service_logs_it_in(self, http):
        resp = http.post("/auth/login", json={"username": NAME, "password": PASSWORD})
        assert resp.status_code == 200, resp.json()
        token = resp.json()["data"]["token"]
        me = http.get("/auth/me", headers=_bearer(token))
        assert me.json()["data"]["role"] == "superadmin"
        assert http.get("/auth/users", headers=_bearer(token)).status_code == 200

    def test_04_a_second_run_is_refused(self):
        done = _add(NAME, PASSWORD + "\n")
        assert (done.returncode, done.stdout) == (7, "USER_ALREADY_EXISTS\n")

    def test_05_cleanup(self, http, superadmin_token):
        resp = http.delete(f"/auth/users/{NAME}", headers=_bearer(superadmin_token))
        assert resp.status_code == 200
