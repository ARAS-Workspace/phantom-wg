"""
Firewall Bridge E2E — Multihop IPv4.

Phase 1: WireGuard tunnel setup + firewall preset + verify
Phase 2: Crash + recovery from DB + verify restored
Phase 3: Client connects through bridge + end-to-end ping
"""

from __future__ import annotations

import os
import tempfile
import time
from textwrap import dedent

from e2e_tests.tests.conftest import sh, BRIDGE_IP
from e2e_tests.tests.helpers import (
    wg_genkey, wg_genpsk, parse_exit_config,
    setup_wg_main, setup_wg_exit, cleanup_wg,
    ping, MULTIHOP_V4_PRESET,
)

# noinspection DuplicatedCode
class TestMultihopV4:

    def test_full_lifecycle(self, exit_conf_v4, client_exec, client_write_file):
        workdir = tempfile.mkdtemp(prefix="fw-e2e-v4-")
        # Ubuntu's AppArmor profile for /usr/bin/wg (26.04 and later) lets wg
        # open key files only under /etc/wireguard.
        keydir = tempfile.mkdtemp(prefix="fw-e2e-v4-", dir="/etc/wireguard")
        db_path = os.path.join(workdir, "firewall.db")
        exit_cfg = parse_exit_config(exit_conf_v4)

        # ══════════════════════════════════════════════════════
        # PHASE 1: Tunnel + Preset
        # ══════════════════════════════════════════════════════
        print("\n" + "=" * 60, flush=True)
        print("  PHASE 1 — Tunnel Setup + Firewall Preset (IPv4)", flush=True)
        print("=" * 60, flush=True)

        main_keys = setup_wg_main(keydir, "10.0.1.1/24")
        setup_wg_exit(keydir, exit_cfg)
        sh("sysctl -w net.ipv4.ip_forward=1")
        time.sleep(5)

        sh("wg show wg_main", check=False)
        sh("wg show wg_exit", check=False)

        assert ping("10.0.1.1"), "wg_main not reachable"
        assert ping("10.0.2.1"), "exit-server not reachable via wg_exit"

        from firewall_bridge import FirewallBridge
        from firewall_bridge.presets import apply_preset

        bridge = FirewallBridge(db_path)
        bridge.start()
        apply_preset(bridge, MULTIHOP_V4_PRESET)
        print("  Preset applied: multihop-exit", flush=True)

        sh("nft list table inet phantom", check=False)
        sh("ip rule show", check=False)

        fw_rules = bridge.list_firewall_rules("multihop-exit")
        rt_rules = bridge.list_routing_rules("multihop-exit")
        assert len(fw_rules) == 3
        assert len(rt_rules) == 4
        print("  PHASE 1 PASSED", flush=True)

        # ══════════════════════════════════════════════════════
        # PHASE 2: Crash + Recovery
        # ══════════════════════════════════════════════════════
        print("\n" + "=" * 60, flush=True)
        print("  PHASE 2 — Crash + Recovery (IPv4)", flush=True)
        print("=" * 60, flush=True)

        bridge.close()
        sh("nft flush table inet phantom", check=False)
        sh("nft delete table inet phantom", check=False)

        bridge2 = FirewallBridge(db_path)
        assert bridge2.get_state() == "stopped"
        bridge2.start()

        r = sh("nft list table inet phantom")
        assert "wg_main" in r.stdout
        assert "masquerade" in r.stdout
        assert ping("10.0.2.1"), "exit-server not reachable after recovery"
        print("  PHASE 2 PASSED", flush=True)

        # ══════════════════════════════════════════════════════
        # PHASE 3: Client E2E
        # ══════════════════════════════════════════════════════
        print("\n" + "=" * 60, flush=True)
        print("  PHASE 3 — Client Connects (IPv4)", flush=True)
        print("=" * 60, flush=True)

        client_priv, client_pub = wg_genkey()
        client_psk = wg_genpsk()

        psk_file = os.path.join(keydir, "client.psk")
        with open(psk_file, "w") as f:
            f.write(client_psk)
        sh(f"wg set wg_main peer {client_pub} "
           f"preshared-key {psk_file} "
           f"allowed-ips 10.0.1.2/32 "
           f"persistent-keepalive 25")

        client_conf = dedent(f"""\
            [Interface]
            PrivateKey = {client_priv}
            Address = 10.0.1.2/24

            [Peer]
            PublicKey = {main_keys['pub']}
            PresharedKey = {client_psk}
            AllowedIPs = 10.0.1.0/24, 10.0.2.0/24
            Endpoint = {BRIDGE_IP}:51820
            PersistentKeepalive = 1
        """)

        client_write_file("/etc/wireguard/wg0.conf", client_conf)
        client_exec("wg-quick up wg0")
        time.sleep(5)

        client_exec("wg show wg0", check=False)
        sh("wg show wg_main", check=False)

        rc, _ = client_exec("ping -c3 -W2 10.0.1.1", check=False)
        assert rc == 0, "client → wg_main failed"

        rc, _ = client_exec("ping -c3 -W2 10.0.2.1", check=False)
        assert rc == 0, "client → exit-server multihop failed"

        sh("nft list table inet phantom", check=False)
        bridge2.close()
        client_exec("wg-quick down wg0", check=False)
        print("  PHASE 3 PASSED", flush=True)

        # Cleanup after success
        cleanup_wg()
