"""
Firewall Bridge E2E — Multihop IPv6.

Phase 1: WireGuard tunnel setup + firewall preset + verify
Phase 2: Crash + recovery from DB + verify restored
Phase 3: Client connects through bridge + end-to-end ping6
"""

from __future__ import annotations

import os
import tempfile
import time
from textwrap import dedent

from e2e_tests.tests.conftest import sh, BRIDGE_IP6
from e2e_tests.tests.helpers import (
    wg_genkey, wg_genpsk, parse_exit_config,
    setup_wg_main, setup_wg_exit, cleanup_wg,
    ping6, MULTIHOP_V6_PRESET,
)


# noinspection DuplicatedCode
class TestMultihopV6:

    def test_full_lifecycle(self, exit_conf_v6, client_exec, client_write_file):
        workdir = tempfile.mkdtemp(prefix="fw-e2e-v6-")
        # Ubuntu's AppArmor profile for /usr/bin/wg (26.04 and later) lets wg
        # open key files only under /etc/wireguard.
        keydir = tempfile.mkdtemp(prefix="fw-e2e-v6-", dir="/etc/wireguard")
        db_path = os.path.join(workdir, "firewall.db")
        exit_cfg = parse_exit_config(exit_conf_v6)

        # Clean stale client wg0 from v4 test
        client_exec("wg-quick down wg0", check=False)
        client_exec("ip link delete wg0", check=False)

        # ══════════════════════════════════════════════════════
        # PHASE 1: Tunnel + Preset
        # ══════════════════════════════════════════════════════
        print("\n" + "=" * 60, flush=True)
        print("  PHASE 1 — Tunnel Setup + Firewall Preset (IPv6)", flush=True)
        print("=" * 60, flush=True)

        main_keys = setup_wg_main(keydir, "fd00:10:1::1/64")
        setup_wg_exit(keydir, exit_cfg)
        sh("sysctl -w net.ipv6.conf.all.forwarding=1")
        time.sleep(5)

        sh("wg show wg_main", check=False)
        sh("wg show wg_exit", check=False)

        assert ping6("fd00:10:1::1"), "wg_main not reachable (IPv6)"
        assert ping6("fd00:10:2::1"), "exit-server not reachable via wg_exit (IPv6)"

        from firewall_bridge import FirewallBridge
        from firewall_bridge.presets import apply_preset

        bridge = FirewallBridge(db_path)
        bridge.start()
        apply_preset(bridge, MULTIHOP_V6_PRESET)
        print("  Preset applied: multihop-exit-v6", flush=True)

        sh("nft list table inet phantom", check=False)
        sh("ip -6 rule show", check=False)

        fw_rules = bridge.list_firewall_rules("multihop-exit-v6")
        rt_rules = bridge.list_routing_rules("multihop-exit-v6")
        assert len(fw_rules) == 3
        assert len(rt_rules) == 4
        assert all(r.family == 10 for r in fw_rules)
        print("  PHASE 1 PASSED", flush=True)

        # ══════════════════════════════════════════════════════
        # PHASE 2: Crash + Recovery
        # ══════════════════════════════════════════════════════
        print("\n" + "=" * 60, flush=True)
        print("  PHASE 2 — Crash + Recovery (IPv6)", flush=True)
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

        r = sh("ip -6 rule show")
        assert "mh6" in r.stdout

        assert ping6("fd00:10:2::1"), "exit-server not reachable after recovery (IPv6)"
        print("  PHASE 2 PASSED", flush=True)

        # ══════════════════════════════════════════════════════
        # PHASE 3: Client E2E
        # ══════════════════════════════════════════════════════
        print("\n" + "=" * 60, flush=True)
        print("  PHASE 3 — Client Connects (IPv6)", flush=True)
        print("=" * 60, flush=True)

        client_priv, client_pub = wg_genkey()
        client_psk = wg_genpsk()

        psk_file = os.path.join(keydir, "client.psk")
        with open(psk_file, "w") as f:
            f.write(client_psk)
        sh(f"wg set wg_main peer {client_pub} "
           f"preshared-key {psk_file} "
           f"allowed-ips fd00:10:1::2/128 "
           f"persistent-keepalive 25")

        client_conf = dedent(f"""\
            [Interface]
            PrivateKey = {client_priv}
            Address = fd00:10:1::2/64

            [Peer]
            PublicKey = {main_keys['pub']}
            PresharedKey = {client_psk}
            AllowedIPs = fd00:10:1::/64, fd00:10:2::/64
            Endpoint = [{BRIDGE_IP6}]:51820
            PersistentKeepalive = 1
        """)

        client_write_file("/etc/wireguard/wg0.conf", client_conf)
        client_exec("wg-quick up wg0")
        time.sleep(5)

        client_exec("wg show wg0", check=False)
        sh("wg show wg_main", check=False)

        rc, _ = client_exec("ping -6 -c3 -W2 fd00:10:1::1", check=False)
        assert rc == 0, "client → wg_main failed (IPv6)"

        rc, _ = client_exec("ping -6 -c3 -W2 fd00:10:2::1", check=False)
        assert rc == 0, "client → exit-server multihop failed (IPv6)"

        sh("nft list table inet phantom", check=False)
        bridge2.close()
        client_exec("wg-quick down wg0", check=False)
        print("  PHASE 3 PASSED", flush=True)

        # Cleanup after success
        cleanup_wg()
