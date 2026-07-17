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

Chaos E2E: Ungraceful Shutdown Recovery

Tests daemon resilience against SIGKILL — immediate process termination
without graceful shutdown. Unlike `docker restart` (SIGTERM → cleanup →
SIGKILL after timeout), SIGKILL terminates instantly:

  - Lifespan shutdown handlers do NOT run
  - UDS socket is NOT cleaned up by the application
  - WireGuard interface may be orphaned in the kernel
  - SQLite WAL/journal may contain uncommitted pages
  - Firewall nft context is NOT released

Topology (same compose stack as test_daemon_restart.py):

    ┌───────────┐     ┌──────────┐     ┌───────────────┐
    │  client   │────→│  daemon  │────→│  exit-server  │
    │ (wg-quick)│ WG  │ (wg_main │ WG  │  (wg0)        │
    └───────────┘ UDP │  wg_exit)│ UDP └───────────────┘
                      └────┬─────┘          10.0.2.1
                           │ UDS
                      ┌────┴─────┐
                      │ gateway  │ ←── master (pytest)
                      │ (socat)  │     HTTP :9080
                      └──────────┘

    Named volumes: daemon-db, daemon-state (persist across kills)

Scenarios:

  A — SIGKILL Recovery
      Build full state (client + multihop) → SIGKILL (no graceful
      shutdown) → restart → verify state intact + E2E connectivity.

  B — Rapid Restart Storm
      5× consecutive SIGKILL → start cycles with minimal delay.
      Daemon must recover cleanly every time. Final state must be
      identical to pre-storm snapshot. No duplicate entries, no
      leaked resources.

  C — Mid-flight Kill (CIDR expansion + concurrent client creation)
      Expand subnet to /16 (65,533 slots) → spawn worker thread that
      creates clients as fast as possible → SIGKILL at a random
      interval (2–6 seconds) → restart → verify DB consistency:
      every client is either fully committed (all fields populated)
      or fully absent (404). No partial state allowed. Pool counts
      must match actual data. Terazi (IPv4↔IPv6 balance) must pass
      validation.

Run with -s to see live output:
    pytest e2e_tests/chaos/tests/test_ungraceful_shutdown.py -s
"""

from __future__ import annotations

import functools
import ipaddress
import random
import threading
import time

import pytest
import requests


# Force line-by-line flush so output streams live under pytest -s
# noinspection PyShadowingBuiltins
print = functools.partial(print, flush=True)


from .helpers import (
    _SEP,
    _THIN,
    _adapt_config,
    _all_client_names,
    _bulk_assign,
    _bulk_revoke,
    _elapsed,
    _exec_log,
    _gateway_ip_from_conf,
    _get_server_state,
    _health_check,
    _info,
    _phase,
    _print_connectivity,
    _print_health_check,
    _print_server_state,
    _print_wg_show,
    _setup_client_wg,
    _teardown_client,
)


# ══════════════════════════════════════════════════════════════════
#  SCENARIO A — SIGKILL RECOVERY
# ══════════════════════════════════════════════════════════════════

class TestSigkillRecovery:
    """SIGKILL with full state (client + multihop) → restart → verify."""

    # Phase A1 — Setup
    def test_setup_client(self, api):
        t0 = time.perf_counter()
        _phase("A1 — CLIENT SETUP")

        resp = api.post("/api/core/clients/assign", body={"name": "kill-client"})
        assert resp.status_code == 201

        data = resp.json()["data"]
        _info("name", data["name"])
        _info("ipv4", data["ipv4_address"])
        _info("ipv6", data.get("ipv6_address", ""))
        _info("public key", data["public_key_hex"][:16] + "...")
        _elapsed(t0)

    def test_setup_multihop(self, api, exit_conf):
        t0 = time.perf_counter()
        _phase("A1 — MULTIHOP SETUP")

        resp = api.post("/api/multihop/import", body={"name": "kill-exit", "config": exit_conf})
        assert resp.status_code == 201
        _info("exit", resp.json()["data"]["name"])

        resp = api.post("/api/multihop/enable", body={"name": "kill-exit"})
        assert resp.status_code == 200
        _info("status", resp.json()["data"]["status"])

        time.sleep(5)
        _elapsed(t0)

    # Phase A2 — Pre-kill snapshot
    def test_pre_kill_state(self, api, container_exec):
        t0 = time.perf_counter()
        _phase("A2 — PRE-KILL STATE SNAPSHOT")

        mh, fw_groups = _get_server_state(api)
        assert mh["enabled"] is True
        assert "multihop-exit" in fw_groups

        _print_server_state(multihop=mh, fw_groups=fw_groups)

        rc, out = container_exec("daemon", "ping -c 3 -W 2 10.0.2.1", check=False)
        _exec_log("daemon -> exit", rc, out)
        assert rc == 0

        _elapsed(t0)

    # Phase A3 — SIGKILL
    def test_sigkill(self, kill_daemon):
        t0 = time.perf_counter()
        _phase("A3 — SIGKILL (no graceful shutdown)")

        recovery_time = kill_daemon(timeout=60)
        _info("recovery time", f"{recovery_time:.2f}s")
        _elapsed(t0)

    # Phase A4 — Post-kill verification
    def test_post_kill_state(self, api, container_exec):
        t0 = time.perf_counter()
        _phase("A4 — POST-KILL STATE VERIFICATION")

        mh, fw_groups = _get_server_state(api)
        assert mh["enabled"] is True, f"multihop not recovered: {mh}"
        assert mh["active"] == "kill-exit"
        assert "multihop-exit" in fw_groups

        _print_server_state(multihop=mh, fw_groups=fw_groups)

        time.sleep(5)
        rc, out = container_exec("daemon", "ping -c 3 -W 2 10.0.2.1", check=False)
        _exec_log("daemon -> exit", rc, out)
        assert rc == 0

        _elapsed(t0)

    def test_post_kill_client_e2e(self, api, container_exec, container_write_file):
        t0 = time.perf_counter()
        _phase("A4 — CLIENT E2E (raw WG/UDP -> multihop -> exit)")

        conf = _setup_client_wg(api, container_exec, container_write_file, version="hybrid")
        _print_wg_show(container_exec)

        gw = _gateway_ip_from_conf(conf)
        _print_connectivity(container_exec, [
            (gw, "client -> daemon WG", True),
            ("10.0.2.1", "client -> exit (mhop)", True),
            ("fd10:0:2::1", "client -> exit v6 (mhop)", True),
        ])
        _elapsed(t0)

    # Phase A5 — Cleanup
    def test_cleanup(self, api, container_exec):
        t0 = time.perf_counter()
        _phase("A5 — CLEANUP")

        _teardown_client(container_exec)
        api.post("/api/multihop/disable")
        api.post("/api/multihop/remove", body={"name": "kill-exit"})
        api.post("/api/core/clients/revoke", body={"name": "kill-client"})

        _info("exit", "kill-exit removed")
        _info("client", "kill-client revoked")
        _elapsed(t0)

        print(f"\n{_SEP}")
        print("  SCENARIO A PASSED")
        print(f"{_SEP}\n")


# ══════════════════════════════════════════════════════════════════
#  SCENARIO B — RAPID RESTART STORM
# ══════════════════════════════════════════════════════════════════

class TestRapidRestartStorm:
    """5× consecutive SIGKILL → start with no delay between cycles."""

    STORM_ROUNDS = 5

    # Phase B1 — Setup
    def test_setup(self, api, exit_conf):
        t0 = time.perf_counter()
        _phase("B1 — STORM SETUP")

        resp = api.post("/api/core/clients/assign", body={"name": "storm-anchor"})
        assert resp.status_code == 201
        _info("client", resp.json()["data"]["name"])

        resp = api.post("/api/multihop/import", body={"name": "storm-exit", "config": exit_conf})
        assert resp.status_code == 201

        resp = api.post("/api/multihop/enable", body={"name": "storm-exit"})
        assert resp.status_code == 200
        _info("multihop", "enabled")

        time.sleep(3)
        _elapsed(t0)

    # Phase B2 — Pre-storm snapshot
    def test_pre_storm_snapshot(self, api):
        t0 = time.perf_counter()
        _phase("B2 — PRE-STORM SNAPSHOT")

        mh, fw_groups = _get_server_state(api)
        assert mh["enabled"] is True
        assert mh["active"] == "storm-exit"

        resp = api.get("/api/core/clients/list?limit=100")
        clients = resp.json()["data"]["clients"]
        client_names = [c["name"] for c in clients]
        assert "storm-anchor" in client_names

        _print_server_state(multihop=mh, fw_groups=fw_groups)
        _info("clients", ", ".join(client_names))
        _elapsed(t0)

    # Phase B3 — Storm
    def test_storm(self, kill_daemon, gateway_url):
        _phase("B3 — RAPID RESTART STORM")

        recovery_times = []
        for i in range(self.STORM_ROUNDS):
            print(f"\n  Round {i + 1}/{self.STORM_ROUNDS}")
            print(f"  {'─' * 40}")

            recovery = kill_daemon(timeout=60)
            recovery_times.append(recovery)
            _info("recovery time", f"{recovery:.2f}s")

            # Health check — validate full state after each round
            checks = _health_check(gateway_url, expected_client="storm-anchor", expected_exit="storm-exit")
            _print_health_check(i + 1, checks)
            failed = [c for c in checks if not c[1]]
            assert not failed, (
                f"Round {i + 1} health check failed: "
                + ", ".join(f"{name}={status}" for name, _, status in failed)
            )

        print(f"\n{_THIN}")
        print("  Storm Summary")
        print(f"{_THIN}")
        for i, rt in enumerate(recovery_times):
            _info(f"round {i + 1}", f"{rt:.2f}s")
        avg = sum(recovery_times) / len(recovery_times)
        _info("average", f"{avg:.2f}s")
        _info("max", f"{max(recovery_times):.2f}s")

    # Phase B4 — Post-storm verification
    def test_post_storm_state(self, api):
        t0 = time.perf_counter()
        _phase("B4 — POST-STORM STATE VERIFICATION")

        mh, fw_groups = _get_server_state(api)
        assert mh["enabled"] is True, f"multihop lost after storm: {mh}"
        assert mh["active"] == "storm-exit"
        assert "multihop-exit" in fw_groups

        _print_server_state(multihop=mh, fw_groups=fw_groups)

        resp = api.get("/api/core/clients/list?limit=100")
        data = resp.json()["data"]
        client_names = [c["name"] for c in data["clients"]]
        assert "storm-anchor" in client_names
        assert data["total"] == 1, f"Expected 1 client, got {data['total']} (duplicates?)"

        _info("clients", ", ".join(client_names))
        _info("total", str(data["total"]))
        _elapsed(t0)

    # Phase B5 — Cleanup
    def test_cleanup(self, api):
        t0 = time.perf_counter()
        _phase("B5 — STORM CLEANUP")

        api.post("/api/multihop/disable")
        api.post("/api/multihop/remove", body={"name": "storm-exit"})
        api.post("/api/core/clients/revoke", body={"name": "storm-anchor"})

        _info("exit", "storm-exit removed")
        _info("client", "storm-anchor revoked")
        _elapsed(t0)

        print(f"\n{_SEP}")
        print("  SCENARIO B PASSED")
        print(f"{_SEP}\n")


# ══════════════════════════════════════════════════════════════════
#  SCENARIO C — MID-FLIGHT KILL
# ══════════════════════════════════════════════════════════════════

class TestMidflightKill:
    """SIGKILL during CIDR expansion + rapid concurrent client creation.

    Strategy:
        1. Expand CIDR to /16 — maximum capacity (65,533 slots).
           This is a heavy DB operation: DELETE all rows from the
           users table, then INSERT 65,533 new IPv4/IPv6 pairs.

        2. Spawn a worker thread that creates clients as fast as
           the API allows. Each client gets a sequential name
           (storm-0000, storm-0001, ...). The thread records the
           outcome of each request: 201 (committed), connection
           error (daemon died mid-request), or other status code.

        3. After a random delay (2–6 seconds), the main thread
           sends SIGKILL to the daemon container. The worker thread
           will hit a connection error and stop.

        4. Restart daemon and wait for API readiness.

        5. Consistency verification — the critical assertion:
           - Every storm-XXXX client that exists in the DB must be
             fully committed: id, name, ipv4, ipv6, public_key,
             private_key, preshared_key all non-null.
           - Every storm-XXXX client that does NOT exist must return
             404 — no orphaned IP slots with partial data.
           - Pool arithmetic: assigned + free == total.
           - Terazi validation: GET /api/core/network/validate must
             return valid=true (IPv4↔IPv6 index parity intact).

        6. Cleanup: revoke all storm-* clients, shrink CIDR back
           to /24 (default).

    This tests SQLite transaction atomicity under SIGKILL — the WAL
    journal must either replay committed transactions or discard
    incomplete ones on recovery.
    """

    _results: dict[str, int | str] = {}
    _committed: list[str] = []
    _lost: list[str] = []
    _actual_committed: list[str] = []

    # Phase C1 — CIDR expansion to /16
    def test_expand_cidr(self, api):
        t0 = time.perf_counter()
        _phase("C1 — CIDR EXPANSION TO /16")

        resp = api.post("/api/core/network/cidr", body={"prefix": 16})
        assert resp.status_code == 200

        data = resp.json()["data"]
        pool = data["pool"]
        _info("ipv4 subnet", data["ipv4_subnet"])
        _info("ipv6 subnet", data["ipv6_subnet"])
        _info("total slots", str(pool["total"]))
        _info("assigned", str(pool["assigned"]))
        _info("free", str(pool["free"]))
        assert pool["total"] == 65533

        _elapsed(t0)

    # Phase C2 — Mid-flight kill
    def test_midflight_kill(self, gateway_url, sigkill_daemon, start_daemon):
        t0 = time.perf_counter()
        _phase("C2 — CONCURRENT CREATION + SIGKILL")

        results: dict[str, int | str] = {}
        stop_event = threading.Event()
        kill_delay = random.uniform(2.0, 6.0)

        _info("planned kill delay", f"{kill_delay:.2f}s")

        def _worker():
            """Create clients until stopped or connection dies."""
            i = 0
            while not stop_event.is_set():
                name = f"storm-{i:04d}"
                try:
                    resp = requests.post(
                        f"{gateway_url}/api/core/clients/assign",
                        json={"name": name},
                        timeout=5,
                    )
                    results[name] = resp.status_code
                except (requests.ConnectionError, requests.Timeout):
                    results[name] = "lost"
                    break
                except Exception as exc:
                    results[name] = f"error:{exc}"
                    break
                i += 1

        thread = threading.Thread(target=_worker, daemon=True)
        thread.start()

        time.sleep(kill_delay)

        print(f"\n  >>> SIGKILL at {kill_delay:.2f}s")
        sigkill_daemon()
        stop_event.set()
        thread.join(timeout=15)

        # Classify results
        committed = [n for n, s in results.items() if s == 201]
        lost = [n for n, s in results.items() if s == "lost"]
        errored = [n for n, s in results.items()
                   if s not in (201, "lost") and isinstance(s, int)]

        print(f"\n{_THIN}")
        print("  Worker Results (pre-kill)")
        print(f"{_THIN}")
        _info("total attempted", str(len(results)))
        _info("committed (201)", str(len(committed)))
        _info("lost (conn error)", str(len(lost)))
        _info("other errors", str(len(errored)))
        if errored:
            for n in errored[:5]:
                _info(f"  {n}", str(results[n]))

        # Store results for next phase
        self.__class__._results = results
        self.__class__._committed = committed
        self.__class__._lost = lost

        # Restart daemon
        print(f"\n  >>> Restarting daemon...")
        recovery = start_daemon(timeout=90)
        _info("recovery time", f"{recovery:.2f}s")

        _elapsed(t0)

    # Phase C3 — Consistency verification
    def test_consistency(self, gateway_url):
        t0 = time.perf_counter()
        _phase("C3 — DB CONSISTENCY VERIFICATION")

        results = self.__class__._results
        committed = self.__class__._committed
        lost = self.__class__._lost
        attempted_names = sorted(results.keys())

        # Check each attempted client individually
        actual_committed = []
        actual_absent = []
        inconsistent = []

        for name in attempted_names:
            resp = requests.post(
                f"{gateway_url}/api/core/clients/get",
                json={"name": name},
                timeout=10,
            )
            if resp.status_code == 200:
                client = resp.json()["data"]
                # Must be fully committed — all fields populated
                fields = [
                    "id", "name", "ipv4_address", "ipv6_address",
                    "public_key_hex", "private_key_hex", "preshared_key_hex",
                ]
                missing = [f for f in fields if not client.get(f)]
                if missing:
                    inconsistent.append((name, f"missing fields: {missing}"))
                else:
                    actual_committed.append(name)
            elif resp.status_code == 404:
                actual_absent.append(name)
            else:
                inconsistent.append((name, f"unexpected status: {resp.status_code}"))

        print(f"\n{_THIN}")
        print("  Client State After Recovery")
        print(f"{_THIN}")
        _info("committed (exist)", str(len(actual_committed)))
        _info("absent (404)", str(len(actual_absent)))
        _info("INCONSISTENT", str(len(inconsistent)))

        if inconsistent:
            print(f"\n  !!! INCONSISTENT CLIENTS:")
            for name, reason in inconsistent:
                print(f"      {name}: {reason}")

        assert len(inconsistent) == 0, (
            f"Found {len(inconsistent)} clients with partial state: {inconsistent}"
        )

        # Cross-check: every client we got 201 for should exist
        confirmed_committed_missing = [n for n in committed if n in actual_absent]
        if confirmed_committed_missing:
            print(f"\n  WARNING: {len(confirmed_committed_missing)} clients got 201 "
                  f"but are absent (daemon committed but WAL not flushed)")
            for n in confirmed_committed_missing[:5]:
                print(f"    {n}")

        # "lost" clients may or may not exist (in-flight during kill)
        lost_but_committed = [n for n in lost if n in actual_committed]
        lost_and_absent = [n for n in lost if n in actual_absent]
        _info("lost → committed", str(len(lost_but_committed)))
        _info("lost → absent", str(len(lost_and_absent)))

        # Store for C4 — avoid duplicate queries
        self.__class__._actual_committed = actual_committed

        _elapsed(t0)

    # Phase C4 — Pool and terazi validation
    def test_pool_validation(self, gateway_url):
        t0 = time.perf_counter()
        _phase("C4 — POOL & TERAZI VALIDATION")

        actual_committed = self.__class__._actual_committed

        # Pool arithmetic
        resp = requests.get(f"{gateway_url}/api/core/network", timeout=10)
        assert resp.status_code == 200
        pool = resp.json()["data"]["pool"]

        _info("pool total", str(pool["total"]))
        _info("pool assigned", str(pool["assigned"]))
        _info("pool free", str(pool["free"]))
        _info("actual committed", str(len(actual_committed)))

        assert pool["assigned"] == len(actual_committed), (
            f"Pool says {pool['assigned']} assigned but found "
            f"{len(actual_committed)} committed clients"
        )
        assert pool["assigned"] + pool["free"] == pool["total"], (
            f"Pool arithmetic mismatch: {pool['assigned']} + "
            f"{pool['free']} != {pool['total']}"
        )

        # Terazi validation (IPv4 ↔ IPv6 index parity)
        resp = requests.get(f"{gateway_url}/api/core/network/validate", timeout=30)
        assert resp.status_code == 200
        validation = resp.json()["data"]
        _info("terazi valid", str(validation["valid"]))
        if not validation["valid"]:
            for err in validation.get("errors", [])[:5]:
                print(f"    ERROR: {err}")
        assert validation["valid"], f"Terazi validation failed: {validation}"

        _elapsed(t0)

    # Phase C5 — Cleanup
    def test_cleanup(self, gateway_url):
        t0 = time.perf_counter()
        _phase("C5 — CLEANUP (revoke all + CIDR reset)")

        # Revoke all storm-* clients
        revoked = 0
        for name in sorted(self.__class__._results.keys()):
            resp = requests.post(
                f"{gateway_url}/api/core/clients/revoke",
                json={"name": name},
                timeout=10,
            )
            if resp.status_code == 200:
                revoked += 1

        _info("revoked", str(revoked))

        # Shrink CIDR back to /24 (default)
        resp = requests.post(
            f"{gateway_url}/api/core/network/cidr",
            json={"prefix": 24},
            timeout=30,
        )
        assert resp.status_code == 200

        pool = resp.json()["data"]["pool"]
        _info("cidr", resp.json()["data"]["ipv4_subnet"])
        _info("pool total", str(pool["total"]))
        _info("pool assigned", str(pool["assigned"]))
        _info("pool free", str(pool["free"]))
        assert pool["assigned"] == 0
        assert pool["free"] == pool["total"]

        _elapsed(t0)

        print(f"\n{_SEP}")
        print("  SCENARIO C PASSED")
        print(f"{_SEP}\n")

# ══════════════════════════════════════════════════════════════════
#  SCENARIO D — CIDR EXPANSION LEAK (production scale, dual-stack)
# ══════════════════════════════════════════════════════════════════

class TestCidrExpansionLeak:
    """A CIDR expansion must resync every kernel surface, or a client
    allocated outside the old subnet is stranded.

    The /24 is filled (253 clients), then expanded to /23. The first
    client after a full /24 lands on 10.8.0.255 — the old broadcast,
    still INSIDE 10.8.0.0/24, so a stale masquerade covers it and it
    proves nothing. Only 10.8.1.0 is genuinely outside; that is the
    tooth, and D5 asserts the arithmetic so the test cannot silently
    grade the wrong client.

    The exit is dual-stack, so the new-range client must reach it over
    both 10.0.2.1 and fd10:0:2::1 — one test drives fast_sync (peer
    allowed_ips), update_addresses (interface prefix), bootstrap (v4+v6
    masquerade) and resync_multihop (v4+v6 policy) at once, per family.
    """

    _fill = [f"fill-{i:04d}" for i in range(253)]
    _OLD_V4 = ipaddress.ip_network("10.8.0.0/24")
    # The daemon's wg_main gateway is the subnet's first host. The base
    # (10.8.0.0) is fixed across the /24->/23 expansion, so the gateway
    # is 10.8.0.1 for every client — the per-client /24 that
    # _gateway_ip_from_conf would infer is wrong for the new range.
    _GW = "10.8.0.1"

    # Phase D0 — reset to a clean /24
    def test_reset(self, api, gateway_url):
        t0 = time.perf_counter()
        _phase("D0 — RESET TO /24")

        api.post("/api/multihop/disable")
        stale = _all_client_names(gateway_url)
        if stale:
            _info("clearing stale clients", str(len(stale)))
            _bulk_revoke(gateway_url, stale)

        resp = api.post("/api/core/network/cidr", body={"prefix": 24})
        assert resp.status_code == 200
        data = api.get("/api/core/network").json()["data"]
        _info("ipv4 subnet", data["ipv4_subnet"])
        _info("assigned", str(data["pool"]["assigned"]))
        assert data["ipv4_subnet"] == "10.8.0.0/24"
        assert data["pool"]["assigned"] == 0
        _elapsed(t0)

    # Phase D1 — fill the /24
    def test_fill_pool(self, gateway_url):
        t0 = time.perf_counter()
        _phase("D1 — FILL /24 (253 clients)")

        committed = _bulk_assign(gateway_url, self._fill)
        _info("committed", f"{committed}/253")
        assert committed == 253, f"only {committed}/253 committed"
        _elapsed(t0)

    # Phase D2 — dual-stack multihop
    def test_enable_multihop(self, api, exit_conf):
        t0 = time.perf_counter()
        _phase("D2 — DUAL-STACK MULTIHOP")

        resp = api.post("/api/multihop/import",
                        body={"name": "leak-exit", "config": exit_conf})
        assert resp.status_code == 201
        resp = api.post("/api/multihop/enable", body={"name": "leak-exit"})
        assert resp.status_code == 200

        _, groups = _get_server_state(api)
        _print_server_state(fw_groups=groups)
        assert {"multihop-exit", "multihop-exit-v6"} <= set(groups), (
            f"dual-stack exit did not apply both presets: {groups}"
        )
        _elapsed(t0)

    # Phase D3 — baseline: an old-range client reaches the exit (v4 + v6)
    def test_baseline_old_range(self, api, container_exec, container_write_file):
        t0 = time.perf_counter()
        _phase("D3 — BASELINE (old-range client -> exit)")

        conf = _setup_client_wg(
            api, container_exec, container_write_file,
            name="fill-0000", version="hybrid",
        )
        _print_wg_show(container_exec)
        _print_connectivity(container_exec, [
            (self._GW, "old client -> daemon WG", True),
            ("10.0.2.1", "old client -> exit v4", True),
            ("fd10:0:2::1", "old client -> exit v6", True),
        ])
        _teardown_client(container_exec)
        _elapsed(t0)

    # Phase D4 — expand, NO restart (inline resync must carry it)
    def test_expand_cidr(self, api):
        t0 = time.perf_counter()
        _phase("D4 — EXPAND /24 -> /23 (no restart)")

        resp = api.post("/api/core/network/cidr", body={"prefix": 23})
        assert resp.status_code == 200
        data = resp.json()["data"]
        _info("ipv4 subnet", data["ipv4_subnet"])
        _info("total slots", str(data["pool"]["total"]))
        assert data["ipv4_subnet"] == "10.8.0.0/23"
        assert data["pool"]["total"] == 509
        _elapsed(t0)

    # Phase D5 — mint the trap and the tooth, verify the arithmetic
    def test_mint_new_range(self, api):
        t0 = time.perf_counter()
        _phase("D5 — NEW-RANGE CLIENTS (trap + tooth)")

        trap = api.post("/api/core/clients/assign", body={"name": "trap"})
        tooth = api.post("/api/core/clients/assign", body={"name": "tooth"})
        assert trap.status_code == 201 and tooth.status_code == 201
        trap_ip = trap.json()["data"]["ipv4_address"]
        tooth_ip = tooth.json()["data"]["ipv4_address"]
        _info("trap  (inside /24)", trap_ip)
        _info("tooth (outside /24)", tooth_ip)

        assert ipaddress.ip_address(trap_ip) in self._OLD_V4, (
            f"trap {trap_ip} expected inside {self._OLD_V4}"
        )
        assert ipaddress.ip_address(tooth_ip) not in self._OLD_V4, (
            f"tooth {tooth_ip} is inside {self._OLD_V4} — the test proves "
            "nothing; a stale masquerade would still cover it"
        )
        _elapsed(t0)

    # Phase D6 — THE TOOTH: new-range client reaches the exit (v4 + v6)
    def test_tooth_new_range(self, api, container_exec, container_write_file):
        t0 = time.perf_counter()
        _phase("D6 — TOOTH (new-range client -> exit)")

        conf = _setup_client_wg(
            api, container_exec, container_write_file,
            name="tooth", version="hybrid",
        )
        _print_wg_show(container_exec)
        # Without the inline resync: v4 stranded by stale masquerade +
        # policy, v6 by stale mh6 + ip6 masquerade. Both must reach the exit.
        _print_connectivity(container_exec, [
            (self._GW, "new client -> daemon WG", True),
            ("10.0.2.1", "new client -> exit v4", True),
            ("fd10:0:2::1", "new client -> exit v6", True),
        ])
        _teardown_client(container_exec)
        _elapsed(t0)

    # Phase D7 — regression: the old-range client still works
    def test_old_range_still_ok(self, api, container_exec, container_write_file):
        t0 = time.perf_counter()
        _phase("D7 — REGRESSION (old-range client still reaches exit)")

        conf = _setup_client_wg(
            api, container_exec, container_write_file,
            name="fill-0000", version="hybrid",
        )
        _print_connectivity(container_exec, [
            ("10.0.2.1", "old client -> exit v4", True),
            ("fd10:0:2::1", "old client -> exit v6", True),
        ])
        _teardown_client(container_exec)
        _elapsed(t0)

    # Phase D8 — cleanup
    def test_cleanup(self, api, gateway_url):
        t0 = time.perf_counter()
        _phase("D8 — CLEANUP")

        api.post("/api/multihop/disable")
        api.post("/api/multihop/remove", body={"name": "leak-exit"})
        revoked = _bulk_revoke(gateway_url, self._fill + ["trap", "tooth"])
        _info("revoked", str(revoked))
        resp = api.post("/api/core/network/cidr", body={"prefix": 24})
        _info("cidr", resp.json()["data"]["ipv4_subnet"])
        _elapsed(t0)

        print(f"\n{_SEP}")
        print("  SCENARIO D PASSED")
        print(f"{_SEP}\n")
