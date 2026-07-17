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

Chaos E2E: Daemon Restart Recovery (gradual teardown)

Builds full state (client + multihop), restarts daemon,
then gradually tears down each layer with a restart between each
to verify recovery at every degradation level.

Phases:
    1.  Setup: client + multihop
    2.  Pre-restart snapshot (full state)
    3.  Restart #1 — multihop recovery
    4.  Post-restart verification + client E2E via raw WG/UDP
    5.  Multihop disable + client teardown
    6.  Restart #2 — core-only recovery (no multihop)
    7.  Post-restart verification + client E2E (daemon-only)
    8.  Final cleanup

Run with -s to see live output:
    pytest e2e_tests/chaos/tests/test_daemon_restart.py -s
"""

from __future__ import annotations

import functools
import time

import pytest


# Force line-by-line flush so output streams live under pytest -s
# noinspection PyShadowingBuiltins
print = functools.partial(print, flush=True)


from .helpers import (
    _SEP,
    _THIN,
    _adapt_config,
    _elapsed,
    _exec_log,
    _gateway_ip_from_conf,
    _get_server_state,
    _info,
    _phase,
    _print_connectivity,
    _print_server_state,
    _print_wg_show,
    _setup_client_wg,
    _teardown_client,
)


# -- Test class ------------------------------------------------------

class TestDaemonRestart:
    """Daemon restart recovery — gradual teardown with restart at each level."""

    # ================================================================
    #  PHASE 1 — SETUP: CLIENT + MULTIHOP
    # ================================================================

    def test_setup_client(self, api):
        t0 = time.perf_counter()
        _phase("PHASE 1a — CLIENT SETUP")

        resp = api.post("/api/core/clients/assign", body={"name": "chaos-client"})
        assert resp.status_code == 201

        data = resp.json()["data"]
        _info("name", data["name"])
        _info("ipv4", data["ipv4_address"])
        _info("ipv6", data.get("ipv6_address", ""))
        _info("public key", data["public_key_hex"][:16] + "...")
        _elapsed(t0)

    def test_setup_multihop(self, api, exit_conf):
        t0 = time.perf_counter()
        _phase("PHASE 1b — MULTIHOP SETUP")

        resp = api.post("/api/multihop/import", body={"name": "chaos-exit", "config": exit_conf})
        assert resp.status_code == 201

        data = resp.json()["data"]
        _info("exit name", data["name"])
        _info("endpoint", data["endpoint"])
        _info("address", data["address"])
        _info("allowed IPs", data["allowed_ips"])

        resp = api.post("/api/multihop/enable", body={"name": "chaos-exit"})
        assert resp.status_code == 200
        _info("status", resp.json()["data"]["status"])

        time.sleep(5)
        _elapsed(t0)

    # ================================================================
    #  PHASE 2 — PRE-RESTART STATE SNAPSHOT
    # ================================================================

    def test_pre_restart_state(self, api, container_exec):
        t0 = time.perf_counter()
        _phase("PHASE 2 — PRE-RESTART STATE SNAPSHOT")

        mh, fw_groups = _get_server_state(api)
        assert mh["enabled"] is True
        assert "multihop-exit" in fw_groups

        _print_server_state(multihop=mh, fw_groups=fw_groups)

        print(f"\n{_THIN}")
        print("  Daemon Connectivity")
        print(f"{_THIN}")
        rc, out = container_exec("daemon", "ping -c 3 -W 2 10.0.2.1", check=False)
        _exec_log("daemon -> exit", rc, out)
        assert rc == 0

        _elapsed(t0)

    # ================================================================
    #  PHASE 3 — RESTART #1 (MULTIHOP STATE)
    # ================================================================

    def test_restart_multihop(self, restart_daemon):
        t0 = time.perf_counter()
        _phase("PHASE 3 — RESTART #1 (multihop state)")

        recovery_time = restart_daemon(timeout=60)
        _info("recovery time", f"{recovery_time:.2f}s")
        _elapsed(t0)

    # ================================================================
    #  PHASE 4 — POST-RESTART #1 VERIFICATION + CLIENT E2E
    # ================================================================

    def test_multihop_recovery_state(self, api, container_exec):
        t0 = time.perf_counter()
        _phase("PHASE 4a — POST-RESTART #1: STATE VERIFICATION")

        mh, fw_groups = _get_server_state(api)
        assert mh["enabled"] is True, f"multihop not recovered: {mh}"
        assert mh["active"] == "chaos-exit"
        assert "multihop-exit" in fw_groups

        _print_server_state(multihop=mh, fw_groups=fw_groups)

        time.sleep(5)
        print(f"\n{_THIN}")
        print("  Daemon Connectivity")
        print(f"{_THIN}")
        rc, out = container_exec("daemon", "ping -c 3 -W 2 10.0.2.1", check=False)
        _exec_log("daemon -> exit", rc, out)
        assert rc == 0

        _elapsed(t0)

    def test_multihop_recovery_client_e2e(
        self, api, container_exec, container_write_file,
    ):
        t0 = time.perf_counter()
        _phase("PHASE 4b — CLIENT E2E (raw WG/UDP -> multihop -> exit)")

        conf = _setup_client_wg(
            api, container_exec, container_write_file,
            name="chaos-client", version="hybrid",
        )

        _print_wg_show(container_exec, "Client WireGuard (raw UDP)")

        gw = _gateway_ip_from_conf(conf)
        _print_connectivity(container_exec, [
            (gw, "client -> daemon WG", True),
            ("10.0.2.1", "client -> exit (mhop)", True),
            ("fd10:0:2::1", "client -> exit v6 (mhop)", True),
        ])
        _elapsed(t0)

    # ================================================================
    #  PHASE 5 — MULTIHOP DISABLE + CLIENT TEARDOWN
    # ================================================================

    def test_disable_multihop(self, api, container_exec):
        t0 = time.perf_counter()
        _phase("PHASE 5 — MULTIHOP DISABLE")

        _teardown_client(container_exec)

        resp = api.post("/api/multihop/disable")
        assert resp.status_code == 200

        mh, fw_groups = _get_server_state(api)
        assert mh["enabled"] is False

        _print_server_state(multihop=mh, fw_groups=fw_groups)
        _elapsed(t0)

    # ================================================================
    #  PHASE 6 — RESTART #2 (CORE ONLY)
    # ================================================================

    def test_restart_core_only(self, restart_daemon):
        t0 = time.perf_counter()
        _phase("PHASE 6 — RESTART #2 (core only)")

        recovery_time = restart_daemon(timeout=60)
        _info("recovery time", f"{recovery_time:.2f}s")
        _elapsed(t0)

    # ================================================================
    #  PHASE 7 — POST-RESTART #2 VERIFICATION + CLIENT (DAEMON ONLY)
    # ================================================================

    def test_core_only_state(self, api):
        t0 = time.perf_counter()
        _phase("PHASE 7a — POST-RESTART #2: STATE (core only)")

        mh, fw_groups = _get_server_state(api)
        assert mh["enabled"] is False
        assert "multihop-exit" not in fw_groups

        _print_server_state(multihop=mh, fw_groups=fw_groups)

        resp = api.post("/api/core/clients/config", body={"name": "chaos-client", "version": "hybrid"})
        assert resp.status_code == 200
        _info("client config", "exportable")

        _elapsed(t0)

    def test_core_only_client_e2e(
        self, api, container_exec, container_write_file,
    ):
        t0 = time.perf_counter()
        _phase("PHASE 7b — CLIENT E2E (daemon only, no multihop)")

        conf = _setup_client_wg(
            api, container_exec, container_write_file,
            name="chaos-client", version="hybrid",
        )

        _print_wg_show(container_exec, "Client WireGuard (core only)")

        gw = _gateway_ip_from_conf(conf)
        _print_connectivity(container_exec, [
            (gw, "client -> daemon WG", True),
            ("10.0.2.1", "client -> exit", False),
            ("fd10:0:2::1", "client -> exit v6", False),
        ])
        _elapsed(t0)

    # ================================================================
    #  PHASE 8 — FINAL CLEANUP
    # ================================================================

    def test_cleanup(self, api, container_exec):
        t0 = time.perf_counter()
        _phase("PHASE 8 — FINAL CLEANUP")

        _teardown_client(container_exec)

        api.post("/api/multihop/remove", body={"name": "chaos-exit"})
        api.post("/api/core/clients/revoke", body={"name": "chaos-client"})

        _info("exit", "chaos-exit removed")
        _info("client", "chaos-client revoked")

        resp = api.get("/api/multihop/list")
        names = [e["name"] for e in resp.json()["data"]["exits"]]
        assert "chaos-exit" not in names

        _elapsed(t0)

        print(f"\n{_SEP}")
        print("  ALL PHASES PASSED")
        print(f"{_SEP}\n")
