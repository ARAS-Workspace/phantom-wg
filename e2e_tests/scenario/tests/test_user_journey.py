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

Scenario E2E — user journey through auth-service proxy.

Runs INSIDE the master container. All API calls go through auth-service:8443 (JWT).
Tests a complete user journey:

    1.  Login (admin, bootstrap password)
    2.  Health-check (/api/core/hello via proxy)
    3.  Change password
    4.  Re-login (new password)
    5.  Enable TOTP
    6.  Logout
    7.  Login with TOTP (MFA flow)
    8.  Create client config
    9.  Import exit-server + enable multihop
    10. Client E2E (WG raw)
    11. Cleanup
    14. Client pagination
    15. Proxy audit log

Run with -s to see live output:
    pytest e2e_tests/scenario/tests/test_user_journey.py -s
"""

from __future__ import annotations

import base64
import functools
import json
import re
import time
from collections import Counter

import pyotp
import pytest
import requests

# Force line-by-line flush so output streams live under pytest -s
# noinspection PyShadowingBuiltins
print = functools.partial(print, flush=True)


# -- Display helpers -------------------------------------------------

_SEP = "=" * 64
_THIN = "-" * 64


def _api_log(method: str, path: str, resp: requests.Response, body: dict | None = None) -> None:
    """Print API request/response summary."""
    print(f"\n  {method} {path}")
    if body:
        print(f"    request     : {json.dumps(body, ensure_ascii=False)}")
    print(f"    status      : {resp.status_code}")
    try:
        data = resp.json()
        compact = json.dumps(data, indent=2, ensure_ascii=False)
        for line in compact.splitlines()[:20]:
            print(f"    response    : {line}")
        if len(compact.splitlines()) > 20:
            print(f"    response    : ... ({len(compact.splitlines())} lines total)")
    except (ValueError, KeyError):
        print(f"    response    : {resp.text[:200]}")


def _exec_log(label: str, rc: int, out: str) -> None:
    """Print container exec result."""
    status = "OK" if rc == 0 else f"FAIL (rc={rc})"
    print(f"  {label:16s}: {status}")
    if out.strip():
        for line in out.strip().splitlines():
            print(f"    | {line}")


# -- Fixtures --------------------------------------------------------

@pytest.fixture(scope="module")
def api(auth_url):
    """Thin wrapper for authenticated API calls with logging."""

    class _Api:
        def __init__(self, base: str):
            self.base = base
            self.token: str | None = None

        @property
        def _headers(self) -> dict[str, str]:
            if self.token:
                return {"Authorization": f"Bearer {self.token}"}
            return {}

        def get(self, path: str) -> requests.Response:
            resp = requests.get(f"{self.base}{path}", headers=self._headers, timeout=10)
            _api_log("GET", path, resp)
            return resp

        def post(self, path: str, body: dict | None = None, **kwargs) -> requests.Response:
            if body is not None:
                kwargs["json"] = body
            resp = requests.post(
                f"{self.base}{path}", headers=self._headers, timeout=10, **kwargs,
            )
            _api_log("POST", path, resp, body=body)
            return resp

        def delete(self, path: str) -> requests.Response:
            resp = requests.delete(f"{self.base}{path}", headers=self._headers, timeout=10)
            _api_log("DELETE", path, resp)
            return resp

    return _Api(auth_url)


@pytest.fixture(scope="module")
def exit_conf(container_exec, container_ip):
    """Read exit-server WG config with resolved IP."""
    for _ in range(30):
        rc, out = container_exec("exit-server", "cat /config/client.conf", check=False)
        if rc == 0 and "PublicKey" in out:
            break
        time.sleep(1)
    else:
        pytest.fail("exit-server config not ready after 30s")

    exit_ip = container_ip("exit-server")
    _, conf = container_exec("exit-server", "cat /config/client.conf")
    return conf.replace("__EXIT_SERVER_IP__", exit_ip)


@pytest.fixture(scope="module")
def daemon_ip(container_ip):
    """Daemon container IP on E2E network."""
    return container_ip("daemon")


# -- Test class ------------------------------------------------------

class TestUserJourney:
    """Full user journey through auth-service — 15 phases."""

    _NEW_PASSWORD: str = "Sc3n@r10-E2E-N3wP@ss!"
    _totp_secret: str = ""
    _CLIENT_COUNT: int = 100  # clients of PHASE 12

    # ================================================================
    #  PHASE 1 — LOGIN (BOOTSTRAP PASSWORD)
    # ================================================================

    def test_login(self, api, admin_password):
        """Login with bootstrap admin credentials."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 1 — LOGIN (BOOTSTRAP PASSWORD)")
        print(f"{_SEP}")

        resp = api.post("/auth/login", body={
            "username": "admin",
            "password": admin_password,
        })
        assert resp.status_code == 200, f"login: {resp.status_code} {resp.text}"
        assert resp.json()["ok"] is True

        data = resp.json()["data"]
        assert "token" in data
        api.token = data["token"]

        print(f"\n  Token         : {data['token'][:32]}...")
        print(f"  Expires in    : {data['expires_in']}s")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 2 — HEALTH-CHECK (PROXY)
    # ================================================================

    def test_hello(self, api):
        """Health-check via auth proxy → daemon /api/core/hello."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 2 — HEALTH-CHECK (PROXY)")
        print(f"{_SEP}")

        resp = api.get("/api/core/hello")
        assert resp.status_code == 200, f"hello: {resp.status_code} {resp.text}"
        assert resp.json()["ok"] is True

        data = resp.json()["data"]
        print(f"\n  Message       : {data['message']}")
        print(f"  Version       : {data['version']}")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 3 — CHANGE PASSWORD
    # ================================================================

    def test_change_password(self, api):
        """Change admin password via auth API."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 3 — CHANGE PASSWORD")
        print(f"{_SEP}")

        resp = api.post("/auth/users/admin/password", body={
            "password": self._NEW_PASSWORD,
        })
        assert resp.status_code == 200, f"change pw: {resp.status_code} {resp.text}"
        assert resp.json()["ok"] is True

        print("\n  Password      : changed")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 4 — RE-LOGIN (NEW PASSWORD)
    # ================================================================

    def test_relogin(self, api):
        """Re-login with the new password."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 4 — RE-LOGIN (NEW PASSWORD)")
        print(f"{_SEP}")

        resp = api.post("/auth/login", body={
            "username": "admin",
            "password": self._NEW_PASSWORD,
        })
        assert resp.status_code == 200, f"relogin: {resp.status_code} {resp.text}"

        data = resp.json()["data"]
        api.token = data["token"]

        print(f"\n  Token         : {data['token'][:32]}...")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 5 — ENABLE TOTP
    # ================================================================

    def test_enable_totp(self, api):
        """Enable TOTP MFA for admin user (setup + confirm)."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 5 — ENABLE TOTP")
        print(f"{_SEP}")

        # Step 1: Setup — verify password, get secret + backup codes
        resp = api.post("/auth/totp/setup", body={
            "password": self._NEW_PASSWORD,
        })
        assert resp.status_code == 200, f"totp setup: {resp.status_code} {resp.text}"
        assert resp.json()["ok"] is True

        data = resp.json()["data"]
        assert "setup_token" in data
        assert "secret" in data
        assert "backup_codes" in data

        TestUserJourney._totp_secret = data["secret"]
        setup_token = data["setup_token"]

        print(f"\n  Secret        : {data['secret'][:8]}...")
        print(f"  URI           : {data['uri'][:40]}...")
        print(f"  Backup codes  : {len(data['backup_codes'])} codes")

        # Step 2: Confirm — verify TOTP code to activate
        totp = pyotp.TOTP(data["secret"])
        code = totp.now()

        print(f"  TOTP code     : {code}")

        resp = api.post("/auth/totp/confirm", body={
            "setup_token": setup_token,
            "code": code,
        })
        assert resp.status_code == 200, f"totp confirm: {resp.status_code} {resp.text}"
        assert resp.json()["ok"] is True

        print("  TOTP          : enabled")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 6 — LOGOUT
    # ================================================================

    def test_logout(self, api):
        """Logout — revoke current session."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 6 — LOGOUT")
        print(f"{_SEP}")

        resp = api.post("/auth/logout")
        assert resp.status_code == 200, f"logout: {resp.status_code} {resp.text}"

        # Verify old token is rejected
        resp_check = api.get("/auth/me")
        assert resp_check.status_code == 401

        api.token = None

        print("\n  Session       : revoked")
        print("  Old token     : rejected (401)")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 7 — LOGIN WITH TOTP (MFA FLOW)
    # ================================================================

    def test_login_totp(self, api):
        """Login with TOTP — MFA challenge → verify."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 7 — LOGIN WITH TOTP (MFA FLOW)")
        print(f"{_SEP}")

        # Step 1: Login → MFA challenge
        resp = api.post("/auth/login", body={
            "username": "admin",
            "password": self._NEW_PASSWORD,
        })
        assert resp.status_code == 200, f"mfa login: {resp.status_code} {resp.text}"

        data = resp.json()["data"]
        assert "mfa_token" in data, f"Expected MFA challenge, got: {data}"
        mfa_token = data["mfa_token"]

        print(f"\n  MFA token     : {mfa_token[:32]}...")

        # Step 2: Generate TOTP code and verify
        totp = pyotp.TOTP(self._totp_secret)
        code = totp.now()

        print(f"  TOTP code     : {code}")

        resp = api.post("/auth/mfa/verify", body={
            "mfa_token": mfa_token,
            "code": code,
        })
        assert resp.status_code == 200, f"mfa verify: {resp.status_code} {resp.text}"

        data = resp.json()["data"]
        assert "token" in data
        api.token = data["token"]

        print(f"\n  Access token  : {data['token'][:32]}...")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 8 — CREATE CLIENT CONFIG
    # ================================================================

    def test_assign_client(self, api):
        """Create a test client via daemon API (through proxy)."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 8 — CREATE CLIENT CONFIG")
        print(f"{_SEP}")

        resp = api.post("/api/core/clients/assign", body={"name": "e2e-scenario"})
        assert resp.status_code == 201, f"assign: {resp.status_code} {resp.text}"

        data = resp.json()["data"]
        assert data["name"] == "e2e-scenario"
        assert data["ipv4_address"]
        assert data["private_key_hex"]

        print(f"\n  Client name   : {data['name']}")
        print(f"  IPv4 address  : {data['ipv4_address']}")
        print(f"  Public key    : {data['public_key_hex'][:16]}...")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 9 — MULTIHOP IMPORT + ENABLE
    # ================================================================

    def test_import_exit(self, api, exit_conf):
        """Import exit-server WG config via proxy."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 9a — IMPORT EXIT CONFIG")
        print(f"{_SEP}")

        print("\n  Exit config (from exit-server):")
        for line in exit_conf.strip().splitlines():
            print(f"    | {line}")

        resp = api.post("/api/multihop/import", body={"name": "test-exit", "config": exit_conf})
        assert resp.status_code == 201, f"import: {resp.status_code} {resp.text}"

        resp = api.get("/api/multihop/list")
        assert resp.status_code == 200
        names = [e["name"] for e in resp.json()["data"]["exits"]]
        assert "test-exit" in names
        print(f"\n  Import verify : test-exit in {names}")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    def test_enable_multihop(self, api):
        """Enable multihop via proxy."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 9b — ENABLE MULTIHOP")
        print(f"{_SEP}")

        resp = api.post("/api/multihop/enable", body={"name": "test-exit"})
        assert resp.status_code == 200, f"enable: {resp.status_code} {resp.text}"
        assert resp.json()["data"]["status"] == "enabled"

        resp = api.get("/api/multihop/status")
        status = resp.json()["data"]
        assert status["enabled"] is True

        print(f"\n  Multihop      : enabled={status['enabled']}  active={status['active']}")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 10 — CLIENT E2E (RAW WG)
    # ================================================================

    def test_client_e2e(self, api, container_exec, container_write_file):
        """Client connects through full multihop chain (via proxy config)."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 10 — CLIENT E2E (FULL MULTIHOP CHAIN)")
        print(f"{_SEP}")

        # Export client config via proxy
        resp = api.post(
            "/api/core/clients/config",
            body={"name": "e2e-scenario", "version": "v4"},
        )
        assert resp.status_code == 200, f"config export: {resp.status_code} {resp.text}"

        client_conf_raw = base64.b64decode(resp.json()["data"]).decode()

        print(f"\n{_THIN}")
        print("  Client wg-quick config (from API, raw)")
        print(f"{_THIN}")
        for line in client_conf_raw.strip().splitlines():
            print(f"    | {line}")

        # Adapt config for E2E
        adapted_lines = []
        for line in client_conf_raw.splitlines():
            stripped = line.strip()
            if stripped.startswith("DNS"):
                continue
            if stripped.startswith("Address") and "/32" in stripped:
                line = line.replace("/32", "/24")
            if stripped.startswith("AllowedIPs") and "0.0.0.0/0" in stripped:
                line = line.replace("0.0.0.0/0", "10.0.0.0/8")
            adapted_lines.append(line)
        client_conf = "\n".join(adapted_lines)

        print(f"\n{_THIN}")
        print("  Client wg-quick config (adapted for E2E)")
        print(f"{_THIN}")
        for line in client_conf.strip().splitlines():
            print(f"    | {line}")

        # Write config and bring up client tunnel
        container_write_file("client", "/etc/wireguard/wg0.conf", client_conf)
        container_exec("client", "wg-quick up wg0")
        time.sleep(5)

        # Client WG show
        print(f"\n{_THIN}")
        print("  Client WireGuard state")
        print(f"{_THIN}")
        rc, out = container_exec("client", "wg show wg0", check=False)
        _exec_log("wg show wg0", rc, out)

        # Client -> daemon WG (direct)
        print(f"\n{_THIN}")
        print("  Connectivity: client -> daemon WG")
        print(f"{_THIN}")
        client_addr = ""
        for line in client_conf.splitlines():
            if line.strip().startswith("Address"):
                client_addr = line.split("=", 1)[1].strip().split("/")[0].split(",")[0].strip()
                break
        subnet = client_addr.rsplit(".", 1)[0]
        gateway_ip = f"{subnet}.1"

        rc, out = container_exec("client", f"ping -c 3 -W 2 {gateway_ip}", check=False)
        _exec_log(f"ping {gateway_ip}", rc, out)
        assert rc == 0, f"client cannot reach daemon WG ({gateway_ip})\n{out}"

        # Client -> exit-server (multihop)
        print(f"\n{_THIN}")
        print("  Connectivity: client -> exit-server (multihop)")
        print(f"{_THIN}")
        rc, out = container_exec("client", "ping -c 3 -W 2 10.0.2.1", check=False)
        _exec_log("ping 10.0.2.1", rc, out)
        assert rc == 0, f"client cannot reach exit-server via multihop (10.0.2.1)\n{out}"

        print(f"\n  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 11 — CLEANUP
    # ================================================================

    def test_disable_multihop(self, api, container_exec):
        """Disable multihop and tear down client."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 11a — DISABLE MULTIHOP")
        print(f"{_SEP}")

        container_exec("client", "wg-quick down wg0", check=False)

        resp = api.post("/api/multihop/disable")
        assert resp.status_code == 200

        resp = api.get("/api/multihop/status")
        assert resp.json()["data"]["enabled"] is False

        print("\n  Multihop      : disabled")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    def test_cleanup(self, api):
        """Remove exit config, revoke client, disable TOTP."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 11b — CLEANUP")
        print(f"{_SEP}")

        api.post("/api/multihop/remove", body={"name": "test-exit"})
        api.post("/api/core/clients/revoke", body={"name": "e2e-scenario"})

        resp = api.get("/api/multihop/list")
        names = [e["name"] for e in resp.json()["data"]["exits"]]
        assert "test-exit" not in names

        # Disable TOTP
        resp = api.post("/auth/totp/disable", body={
            "password": self._NEW_PASSWORD,
        })
        assert resp.status_code == 200

        print(f"\n  Exits after   : {names}")
        print("  Client        : e2e-scenario revoked")
        print("  TOTP          : disabled")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 12 — CLIENT PAGINATION
    # ================================================================

    def test_client_pagination(self, api):
        """Create 100 clients, verify paginated list API, then revoke all."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 12 — CLIENT PAGINATION (100 clients)")
        print(f"{_SEP}")

        # noinspection PyPep8Naming
        CLIENT_COUNT = self._CLIENT_COUNT
        names = [f"e2e-pg-{i:03d}" for i in range(1, CLIENT_COUNT + 1)]

        # ── Create 100 clients ───────────────────────────────────
        print(f"\n  Creating {CLIENT_COUNT} clients...")
        for name in names:
            resp = api.post("/api/core/clients/assign", body={"name": name})
            assert resp.status_code == 201, f"assign {name}: {resp.status_code} {resp.text}"
        print(f"  Created   : {CLIENT_COUNT} clients")

        # ── Page 1 (limit=25) — first 25 items ──────────────────
        resp = api.get("/api/core/clients/list?page=1&limit=25&order=asc")
        assert resp.status_code == 200
        data = resp.json()["data"]
        assert data["total"] == CLIENT_COUNT,  f"total mismatch: {data['total']}"
        assert data["pages"] == 4,             f"pages mismatch: {data['pages']}"
        assert data["page"]  == 1
        assert data["limit"] == 25
        assert len(data["clients"]) == 25
        first_name = data["clients"][0]["name"]
        print(f"\n  Page 1/4  : {len(data['clients'])} items — first: {first_name}")

        # ── Page 4 (limit=25) — last 25 items ───────────────────
        resp = api.get("/api/core/clients/list?page=4&limit=25&order=asc")
        assert resp.status_code == 200
        data = resp.json()["data"]
        assert data["page"] == 4
        assert len(data["clients"]) == 25
        last_name = data["clients"][-1]["name"]
        print(f"  Page 4/4  : {len(data['clients'])} items — last: {last_name}")

        # ── Search filter ────────────────────────────────────────
        resp = api.get("/api/core/clients/list?search=e2e-pg-01&limit=100")
        assert resp.status_code == 200
        data = resp.json()["data"]
        # "e2e-pg-01" matches e2e-pg-010..019 only — e2e-pg-001 does NOT contain "e2e-pg-01"
        assert data["total"] == 10, f"search total mismatch: {data['total']}"
        print(f"\n  Search    : 'e2e-pg-01' → {data['total']} matches")

        # ── Order check ──────────────────────────────────────────
        resp_asc  = api.get("/api/core/clients/list?page=1&limit=1&order=asc")
        resp_desc = api.get("/api/core/clients/list?page=1&limit=1&order=desc")
        assert resp_asc.status_code == 200 and resp_desc.status_code == 200
        name_asc  = resp_asc.json()["data"]["clients"][0]["name"]
        name_desc = resp_desc.json()["data"]["clients"][0]["name"]
        assert name_asc != name_desc, "asc and desc first items should differ"
        print(f"  Order asc : first={name_asc}")
        print(f"  Order desc: first={name_desc}")

        # ── Revoke all 100 clients ───────────────────────────────
        print(f"\n  Revoking {CLIENT_COUNT} clients...")
        for name in names:
            resp = api.post("/api/core/clients/revoke", body={"name": name})
            assert resp.status_code == 200, f"revoke {name}: {resp.status_code}"

        # Verify clean slate
        resp = api.get("/api/core/clients/list")
        assert resp.status_code == 200
        assert resp.json()["data"]["total"] == 0

        print(f"  Revoked   : {CLIENT_COUNT} clients — total now 0")
        print(f"\n  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 13 — PROXY AUDIT LOG
    # ================================================================

    # Reads of the journey: the proxy writes none of them.
    _READ_PATHS = ("/api/core/hello", "/api/core/clients/list", "/api/multihop/status")

    def _proxy_rows_of_the_journey(self) -> Counter:
        """(method, path, status) of every call that changes the daemon or
        hands out a key, with the number of its calls in this journey."""
        clients = self._CLIENT_COUNT + 1  # PHASE 8 and PHASE 12
        return Counter({
            ("POST", "/api/core/clients/assign", 201): clients,
            ("POST", "/api/core/clients/config", 200): 1,   # PHASE 10
            ("POST", "/api/core/clients/revoke", 200): clients,
            ("POST", "/api/multihop/import", 201): 1,       # PHASE 9a
            ("GET", "/api/multihop/list", 200): 2,          # PHASE 9a, 11b
            ("POST", "/api/multihop/enable", 200): 1,       # PHASE 9b
            ("POST", "/api/multihop/disable", 200): 1,      # PHASE 11a
            ("POST", "/api/multihop/remove", 200): 1,       # PHASE 11b
        })

    def test_proxy_audit(self, api):
        """The proxy rows hold every change and key handout of the journey,
        with its outcome and its actor, and none of its reads."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 13 — PROXY AUDIT LOG")
        print(f"{_SEP}")

        # ── Every proxy_request row, pages held by the first as_of ──
        rows: list[dict] = []
        as_of = None
        page = 1
        while True:
            query = f"/auth/audit?action=proxy_request&limit=100&order=asc&page={page}"
            if as_of is not None:
                query += f"&as_of={as_of}"
            resp = api.get(query)
            assert resp.status_code == 200, f"audit page {page}: {resp.status_code} {resp.text}"
            data = resp.json()["data"]
            if as_of is None:
                as_of = data["as_of"]
                assert as_of is not None, "No proxy_request audit entries found"
            assert data["as_of"] == as_of, f"page {page} answered as_of {data['as_of']}, sent {as_of}"
            rows.extend(data["items"])
            if page >= data["pages"]:
                break
            page += 1

        total = data["total"]
        ids = [row["id"] for row in rows]
        assert len(ids) == total, f"{len(ids)} rows read in {page} pages, total {total}"
        assert len(set(ids)) == total, "a row came on two pages"
        print(f"\n  Rows        : {total} in {page} pages, as_of {as_of}")

        # ── Row schema ────────────────────────────────────────
        for key in ("id", "user_id", "username", "action", "detail", "ip_address", "timestamp"):
            assert key in rows[0], f"row without {key}: {rows[0]}"
        for key in ("method", "path", "status"):
            assert key in rows[0]["detail"], f"detail without {key}: {rows[0]['detail']}"
        print("  Schema      : valid")

        # ── The actor of every row: the journey's account ─────
        actors = {(row["user_id"], row["username"]) for row in rows}
        assert len(actors) == 1, f"rows of more than one actor: {actors}"
        user_id, username = actors.pop()
        assert username == "admin", f"actor {username!r}, expected 'admin'"
        assert re.fullmatch(r"[0-9a-f]{32}", user_id or ""), f"actor id {user_id!r}"
        print(f"  Actor       : {username} ({user_id})")

        # ── No read is written ────────────────────────────────
        written_paths = {row["detail"]["path"] for row in rows}
        for path in self._READ_PATHS:
            assert path not in written_paths, f"the read {path} is in the audit log"
        print(f"  Reads       : none of {', '.join(self._READ_PATHS)}")

        # ── Every change and key handout, with its outcome ────
        found = Counter(
            (row["detail"]["method"], row["detail"]["path"], row["detail"]["status"])
            for row in rows
        )
        expected = self._proxy_rows_of_the_journey()
        assert found == expected, (
            f"proxy rows differ from the journey\n"
            f"  missing: {dict(expected - found)}\n"
            f"  extra  : {dict(found - expected)}"
        )
        for (method, path, status), count in sorted(expected.items(), key=lambda kv: kv[0][1]):
            print(f"  {count:4d}  {method:4s} {path} {status}")

        print(f"\n  Phase time    : {time.perf_counter() - t0:.2f}s")

        print(f"\n{_SEP}")
        print("  ALL PHASES PASSED")
        print(f"{_SEP}\n")
