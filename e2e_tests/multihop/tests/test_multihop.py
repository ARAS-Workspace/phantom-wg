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

Multihop E2E integration test — fully API-driven.

Runs INSIDE the master container. Uses:
- gateway_url -> daemon API (HTTP via socat)
- container_exec -> docker.sock exec into client container
- container_ip -> container IP discovery

Topology:
    client --WG--> wg_phantom_main --FORWARD--> wg_phantom_exit --WG--> exit-server

API flow:
    1. POST /api/core/clients/assign     -> create client
    2. POST /api/multihop/import+enable   -> multihop setup
    3. Daemon connectivity inspection     -> ping + firewall
    4. POST /api/core/clients/config      -> client WG over raw UDP
    5. Cleanup: multihop disable, revoke

Run with -s to see live output:
    pytest e2e_tests/multihop/tests/test_multihop.py -s
"""

from __future__ import annotations

import base64
import functools
import json
import time

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
def api(gateway_url):
    """Thin wrapper for API calls with logging."""

    class _Api:
        def __init__(self, base: str):
            self.base = base

        def get(self, path: str) -> requests.Response:
            resp = requests.get(f"{self.base}{path}", timeout=10)
            _api_log("GET", path, resp)
            return resp

        def post(self, path: str, body: dict | None = None, **kwargs) -> requests.Response:
            if body is not None:
                kwargs["json"] = body
            resp = requests.post(f"{self.base}{path}", timeout=10, **kwargs)
            _api_log("POST", path, resp, body=body)
            return resp

    return _Api(gateway_url)


@pytest.fixture(scope="module")
def exit_conf(container_exec, container_ip):
    """Read exit-server WG config (IPv4) with resolved IP."""
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
def exit_conf_v6(container_exec, container_ip6):
    """Read exit-server WG config (IPv6) with resolved IP."""
    for _ in range(30):
        rc, out = container_exec("exit-server", "cat /config/client-v6.conf", check=False)
        if rc == 0 and "PublicKey" in out:
            break
        time.sleep(1)
    else:
        pytest.fail("exit-server v6 config not ready after 30s")

    exit_ip6 = container_ip6("exit-server")
    _, conf = container_exec("exit-server", "cat /config/client-v6.conf")
    return conf.replace("__EXIT_SERVER_IP6__", exit_ip6)


# -- Test class ------------------------------------------------------

class TestMultihop:
    """Multihop lifecycle E2E — 5 phases."""

    # ================================================================
    #  PHASE 1 — CLIENT SETUP
    # ================================================================

    def test_assign_client(self, api):
        """Create a test client via API."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 1 — CLIENT SETUP")
        print(f"{_SEP}")

        resp = api.post("/api/core/clients/assign", body={"name": "e2e-client"})
        assert resp.status_code == 201, f"assign: {resp.status_code} {resp.text}"

        data = resp.json()["data"]
        assert data["name"] == "e2e-client"
        assert data["ipv4_address"]
        assert data["private_key_hex"]
        assert data["preshared_key_hex"]

        print(f"\n  Client name   : {data['name']}")
        print(f"  IPv4 address  : {data['ipv4_address']}")
        print(f"  Public key    : {data['public_key_hex'][:16]}...")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 2 — MULTIHOP IMPORT + ENABLE
    # ================================================================

    def test_import_exit(self, api, exit_conf):
        """Import exit-server WG config."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 2a — IMPORT EXIT CONFIG")
        print(f"{_SEP}")

        print("\n  Exit config (from exit-server):")
        for line in exit_conf.strip().splitlines():
            print(f"    | {line}")

        resp = api.post("/api/multihop/import", body={"name": "test-exit", "config": exit_conf})
        assert resp.status_code == 201, f"import: {resp.status_code} {resp.text}"
        assert resp.json()["ok"] is True

        resp = api.get("/api/multihop/list")
        assert resp.status_code == 200
        names = [e["name"] for e in resp.json()["data"]["exits"]]
        assert "test-exit" in names
        print(f"\n  Import verify : test-exit in {names}")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    def test_enable_multihop(self, api):
        """Enable multihop — brings up wg_phantom_exit + firewall preset."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 2b — ENABLE MULTIHOP")
        print(f"{_SEP}")

        resp = api.post("/api/multihop/enable", body={"name": "test-exit"})
        assert resp.status_code == 200, f"enable: {resp.status_code} {resp.text}"
        assert resp.json()["data"]["status"] == "enabled"

        resp = api.get("/api/multihop/status")
        assert resp.status_code == 200
        status = resp.json()["data"]
        assert status["enabled"] is True
        assert status["active"] == "test-exit"

        print(f"\n  Multihop      : enabled={status['enabled']}  active={status['active']}")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 3 — DAEMON CONNECTIVITY + WG/FIREWALL INSPECTION
    # ================================================================

    def test_daemon_reaches_exit(self, api, container_exec):
        """Verify: daemon can ping exit-server through WG tunnel + inspect state."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 3 — DAEMON CONNECTIVITY & STATE INSPECTION")
        print(f"{_SEP}")

        time.sleep(5)

        print(f"\n{_THIN}")
        print("  Connectivity: daemon -> exit-server (10.0.2.1)")
        print(f"{_THIN}")

        # Ping exit-server through IPv4 tunnel (retry — tunnel handshake can be racy)
        for attempt in range(3):
            rc, out = container_exec("daemon", "ping -c 3 -W 2 10.0.2.1", check=False)
            _exec_log(f"ping 10.0.2.1 (attempt {attempt + 1})", rc, out)
            if rc == 0:
                break
            time.sleep(3)
        assert rc == 0, f"daemon cannot reach exit-server (10.0.2.1)\n{out}"

        print(f"\n{_THIN}")
        print("  Firewall state (API)")
        print(f"{_THIN}")

        resp = api.get("/api/core/firewall/groups/list")
        assert resp.status_code == 200
        groups = resp.json()["data"]
        group_names = [g["name"] for g in groups] if isinstance(groups, list) else list(groups.keys()) if isinstance(groups, dict) else []
        print(f"\n  Groups        : {group_names}")

        resp = api.post("/api/core/firewall/rules/list", body={"group": "multihop-exit"})
        if resp.status_code == 200:
            rules = resp.json().get("data", [])
            print(f"  Rules (mhop)  : {len(rules)} rules")

        resp = api.post("/api/core/firewall/routing/list", body={"group": "multihop-exit"})
        if resp.status_code == 200:
            routing = resp.json().get("data", [])
            print(f"  Routing (mhop): {len(routing)} rules")

        resp = api.get("/api/core/firewall/table")
        if resp.status_code == 200:
            table = resp.json().get("data", "")
            table_str = table if isinstance(table, str) else json.dumps(table, indent=2)
            print("\n  nftables dump:")
            for line in table_str.strip().splitlines()[:30]:
                print(f"    | {line}")
            total_lines = len(table_str.strip().splitlines())
            if total_lines > 30:
                print(f"    | ... ({total_lines} lines total)")

        print(f"\n  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 4 — CLIENT E2E (FULL MULTIHOP CHAIN)
    # ================================================================

    def test_client_e2e(self, api, container_exec, container_write_file):
        """Client connects through full multihop chain."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 4 — CLIENT E2E (FULL MULTIHOP CHAIN)")
        print(f"{_SEP}")

        resp = api.post(
            "/api/core/clients/config",
            body={"name": "e2e-client", "version": "v4"},
        )
        assert resp.status_code == 200, f"config export: {resp.status_code} {resp.text}"

        client_conf_raw = base64.b64decode(resp.json()["data"]).decode()

        print(f"\n{_THIN}")
        print("  Client wg-quick config (from API, raw)")
        print(f"{_THIN}")
        for line in client_conf_raw.strip().splitlines():
            print(f"    | {line}")

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

        container_write_file("client", "/etc/wireguard/wg0.conf", client_conf)
        container_exec("client", "wg-quick up wg0")
        time.sleep(5)

        print(f"\n{_THIN}")
        print("  Client WireGuard state")
        print(f"{_THIN}")

        rc, out = container_exec("client", "wg show wg0", check=False)
        _exec_log("wg show wg0", rc, out)

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

        print(f"\n{_THIN}")
        print("  Connectivity: client -> exit-server (multihop)")
        print(f"{_THIN}")

        rc, out = container_exec("client", "ping -c 3 -W 2 10.0.2.1", check=False)
        _exec_log("ping 10.0.2.1", rc, out)
        assert rc == 0, f"client cannot reach exit-server via multihop (10.0.2.1)\n{out}"

        print(f"\n  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 5 — CLEANUP
    # ================================================================

    def test_disable_multihop(self, api, container_exec):
        """Disable multihop and tear down client."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 5a — DISABLE MULTIHOP")
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
        """Remove exit config and revoke client."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 5b — CLEANUP")
        print(f"{_SEP}")

        api.post("/api/multihop/remove", body={"name": "test-exit"})
        api.post("/api/core/clients/revoke", body={"name": "e2e-client"})

        resp = api.get("/api/multihop/list")
        names = [e["name"] for e in resp.json()["data"]["exits"]]
        assert "test-exit" not in names

        print(f"\n  Exits after   : {names}")
        print("  Client        : e2e-client revoked")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")

        print(f"\n{_SEP}")
        print("  ALL PHASES PASSED (IPv4)")
        print(f"{_SEP}\n")


# -- IPv6 Test class -----------------------------------------------

class TestMultihopV6:
    """Multihop lifecycle E2E (IPv6) — 5 phases."""

    # ================================================================
    #  PHASE 1 — CLIENT SETUP
    # ================================================================

    def test_assign_client(self, api):
        """Create a test client via API."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 1 (v6) — CLIENT SETUP")
        print(f"{_SEP}")

        resp = api.post("/api/core/clients/assign", body={"name": "e2e-client-v6"})
        assert resp.status_code == 201, f"assign: {resp.status_code} {resp.text}"

        data = resp.json()["data"]
        assert data["name"] == "e2e-client-v6"
        assert data["ipv6_address"]

        print(f"\n  Client name   : {data['name']}")
        print(f"  IPv6 address  : {data['ipv6_address']}")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 2 — MULTIHOP IMPORT + ENABLE (IPv6)
    # ================================================================

    def test_import_exit_v6(self, api, exit_conf_v6):
        """Import exit-server WG config (IPv6 endpoint)."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 2a (v6) — IMPORT EXIT CONFIG")
        print(f"{_SEP}")

        print("\n  Exit config (IPv6):")
        for line in exit_conf_v6.strip().splitlines():
            print(f"    | {line}")

        resp = api.post("/api/multihop/import", body={"name": "test-exit-v6", "config": exit_conf_v6})
        assert resp.status_code == 201, f"import: {resp.status_code} {resp.text}"
        assert resp.json()["ok"] is True

        resp = api.get("/api/multihop/list")
        assert resp.status_code == 200
        names = [e["name"] for e in resp.json()["data"]["exits"]]
        assert "test-exit-v6" in names
        print(f"\n  Import verify : test-exit-v6 in {names}")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    def test_enable_multihop_v6(self, api):
        """Enable multihop with IPv6 exit."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 2b (v6) — ENABLE MULTIHOP")
        print(f"{_SEP}")

        resp = api.post("/api/multihop/enable", body={"name": "test-exit-v6"})
        assert resp.status_code == 200, f"enable: {resp.status_code} {resp.text}"
        assert resp.json()["data"]["status"] == "enabled"

        resp = api.get("/api/multihop/status")
        assert resp.status_code == 200
        status = resp.json()["data"]
        assert status["enabled"] is True
        assert status["active"] == "test-exit-v6"

        print(f"\n  Multihop      : enabled={status['enabled']}  active={status['active']}")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 3 — DAEMON CONNECTIVITY (IPv6 tunnel)
    # ================================================================

    def test_daemon_reaches_exit_v6(self, api, container_exec):
        """Verify: daemon can ping exit-server through IPv6 WG tunnel."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 3 (v6) — DAEMON CONNECTIVITY & STATE INSPECTION")
        print(f"{_SEP}")

        time.sleep(5)

        print(f"\n{_THIN}")
        print("  Connectivity: daemon -> exit-server (fd10:0:2::1)")
        print(f"{_THIN}")

        # Ping exit-server through IPv6 tunnel (retry — tunnel handshake can be racy)
        for attempt in range(3):
            rc, out = container_exec("daemon", "ping6 -c 3 -W 2 fd10:0:2::1", check=False)
            _exec_log(f"ping6 fd10:0:2::1 (attempt {attempt + 1})", rc, out)
            if rc == 0:
                break
            time.sleep(3)
        assert rc == 0, f"daemon cannot reach exit-server (fd10:0:2::1)\n{out}"

        print(f"\n{_THIN}")
        print("  Firewall state (API)")
        print(f"{_THIN}")

        resp = api.get("/api/core/firewall/groups/list")
        assert resp.status_code == 200
        groups = resp.json()["data"]
        group_names = [g["name"] for g in groups] if isinstance(groups, list) else list(groups.keys()) if isinstance(groups, dict) else []
        print(f"\n  Groups        : {group_names}")

        # Check IPv6 preset applied
        resp = api.post("/api/core/firewall/rules/list", body={"group": "multihop-exit-v6"})
        if resp.status_code == 200:
            rules = resp.json().get("data", [])
            print(f"  Rules (mhop6) : {len(rules)} rules")

        print(f"\n  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 4 — CLIENT E2E (IPv6 MULTIHOP CHAIN)
    # ================================================================

    def test_client_e2e_v6(self, api, container_exec, container_write_file):
        """Client connects through IPv6 multihop chain."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 4 (v6) — CLIENT E2E (IPv6 MULTIHOP CHAIN)")
        print(f"{_SEP}")

        resp = api.post(
            "/api/core/clients/config",
            body={"name": "e2e-client-v6", "version": "v6"},
        )
        assert resp.status_code == 200, f"config export: {resp.status_code} {resp.text}"

        client_conf_raw = base64.b64decode(resp.json()["data"]).decode()

        print(f"\n{_THIN}")
        print("  Client wg-quick config (from API, raw)")
        print(f"{_THIN}")
        for line in client_conf_raw.strip().splitlines():
            print(f"    | {line}")

        # Adapt config for E2E: remove DNS, narrow AllowedIPs to tunnel range
        adapted_lines = []
        for line in client_conf_raw.splitlines():
            stripped = line.strip()
            if stripped.startswith("DNS"):
                continue
            if stripped.startswith("AllowedIPs") and "::/0" in stripped:
                line = line.replace("::/0", "fd00:70:68::/48, fd10::/16")
            adapted_lines.append(line)
        client_conf = "\n".join(adapted_lines)

        print(f"\n{_THIN}")
        print("  Client wg-quick config (adapted for E2E)")
        print(f"{_THIN}")
        for line in client_conf.strip().splitlines():
            print(f"    | {line}")

        container_write_file("client", "/etc/wireguard/wg0.conf", client_conf)
        container_exec("client", "wg-quick up wg0")
        time.sleep(5)

        print(f"\n{_THIN}")
        print("  Client WireGuard state")
        print(f"{_THIN}")

        rc, out = container_exec("client", "wg show wg0", check=False)
        _exec_log("wg show wg0", rc, out)

        print(f"\n{_THIN}")
        print("  Connectivity: client -> daemon WG (IPv6)")
        print(f"{_THIN}")

        # Ping daemon's IPv6 VPN gateway (retry — IPv6 NDP settle time)
        for attempt in range(3):
            rc, out = container_exec("client", "ping6 -c 3 -W 2 fd00:70:68::1", check=False)
            _exec_log(f"ping6 fd00:70:68::1 (attempt {attempt + 1})", rc, out)
            if rc == 0:
                break
            time.sleep(3)
        assert rc == 0, f"client cannot reach daemon WG IPv6 (fd00:70:68::1)\n{out}"

        print(f"\n{_THIN}")
        print("  Connectivity: client -> exit-server (IPv6 multihop)")
        print(f"{_THIN}")

        # Ping exit-server through IPv6 multihop (retry)
        for attempt in range(3):
            rc, out = container_exec("client", "ping6 -c 3 -W 2 fd10:0:2::1", check=False)
            _exec_log(f"ping6 fd10:0:2::1 (attempt {attempt + 1})", rc, out)
            if rc == 0:
                break
            time.sleep(3)
        assert rc == 0, f"client cannot reach exit-server via IPv6 multihop (fd10:0:2::1)\n{out}"

        print(f"\n  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    # ================================================================
    #  PHASE 5 — CLEANUP
    # ================================================================

    def test_disable_multihop_v6(self, api, container_exec):
        """Disable multihop and tear down client."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 5a (v6) — DISABLE MULTIHOP")
        print(f"{_SEP}")

        container_exec("client", "wg-quick down wg0", check=False)

        resp = api.post("/api/multihop/disable")
        assert resp.status_code == 200

        resp = api.get("/api/multihop/status")
        assert resp.json()["data"]["enabled"] is False

        print("\n  Multihop      : disabled")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")
        print(f"{_THIN}")

    def test_cleanup_v6(self, api):
        """Remove exit config and revoke client."""
        t0 = time.perf_counter()

        print(f"\n{_SEP}")
        print("  PHASE 5b (v6) — CLEANUP")
        print(f"{_SEP}")

        api.post("/api/multihop/remove", body={"name": "test-exit-v6"})
        api.post("/api/core/clients/revoke", body={"name": "e2e-client-v6"})

        resp = api.get("/api/multihop/list")
        names = [e["name"] for e in resp.json()["data"]["exits"]]
        assert "test-exit-v6" not in names

        print(f"\n  Exits after   : {names}")
        print("  Client        : e2e-client-v6 revoked")
        print(f"  Phase time    : {time.perf_counter() - t0:.2f}s")

        print(f"\n{_SEP}")
        print("  ALL PHASES PASSED (IPv6)")
        print(f"{_SEP}\n")
