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

Integration test — WireGuard multihop tunnel with PersistentDevice crash recovery.

Topology (3 Docker containers on shared network):

                          Docker Network (wg-bridge-test-net)

    ┌──────────────┐       ┌──────────────────────────────────┐       ┌──────────────┐
    │ client       │       │ bridge (this test code)          │       │ exit-server  │
    │              │  WG   │                                  │  WG   │              │
    │ wg0          │──────►│ wg_main ────fwd────► wg_exit     │─────► │ wg0          │
    │ 10.0.1.2/24  │       │ 10.0.1.1/24       10.0.2.2/24    │       │ 10.0.2.1/24  │
    │              │       │ :51821        table 100 + NAT    │       │ :51820       │
    └──────────────┘       └──────────────────────────────────┘       └──────────────┘

    Multihop data path:
        client ──WG──► wg_main ──FORWARD──► wg_exit ──WG──► exit-server

    Forwarding rules (firewall-bridge preset equivalent):
        ip rule  : 10.0.1.0/24 → routing table 100 → default via wg_exit
        iptables : FORWARD wg_main ↔ wg_exit (stateful), MASQUERADE on wg_exit

    Exit server config delivered via EXIT_SERVER_CONFIGURATION env var
    (standard WireGuard client config — external VPN service provider format).

Test phases:
    Phase 1 — Tunnel establishment
        Create wg_main (VPN server) + wg_exit (exit client), set up multihop
        forwarding, verify ping to exit (10.0.2.1), confirm IPC state
        auto-persisted to SQLite by PersistentDevice.

    Phase 2 — Crash + recovery
        Close both devices, confirm tunnel is down. Wait 10s, recreate
        devices from DB only (no config replay). Verify tunnel restored
        and IPC state matches original configuration.

    Phase 3 — Client connects through bridge
        Generate client keys, add peer to wg_main. Push wg-quick config
        to client container via Docker socket. Verify end-to-end multihop:
        client(10.0.1.2) → wg_main → wg_exit → exit-server(10.0.2.1).

Requires: Docker (3 containers), orchestrated by test_runner.py.
"""

import base64
import logging
import os
import shutil
import sqlite3
import subprocess
import tempfile
import time

import pytest

from .conftest import sh, create_device_db, client_exec, client_write_file

log = logging.getLogger("integration.tunnel")
pytestmark = pytest.mark.docker


def _parse_wg_config(conf: str) -> dict:
    """Parse standard WireGuard client config."""
    result = {}
    for line in conf.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("["):
            continue
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        key, val = key.strip(), val.strip()

        if key == "PrivateKey":
            result["client_priv_b64"] = val
            result["client_priv_hex"] = base64.b64decode(val).hex()
        elif key == "Address":
            result["client_ip"] = val
        elif key == "PublicKey":
            result["server_pub_b64"] = val
            result["server_pub_hex"] = base64.b64decode(val).hex()
        elif key == "PresharedKey":
            result["psk_b64"] = val
            result["psk_hex"] = base64.b64decode(val).hex()
        elif key == "Endpoint":
            result["endpoint"] = val
        elif key == "AllowedIPs":
            result["allowed_ips"] = val
    return result


def _get_exit_config() -> dict:
    """Read EXIT_SERVER_CONFIGURATION env var — raw WireGuard client config."""
    raw = os.environ.get("EXIT_SERVER_CONFIGURATION", "")
    if not raw:
        pytest.skip("EXIT_SERVER_CONFIGURATION not set (provided by test_runner)")

    cfg = _parse_wg_config(raw)
    if "endpoint" not in cfg or "client_priv_hex" not in cfg:
        pytest.skip("EXIT_SERVER_CONFIGURATION incomplete")

    log.info("Exit config: endpoint=%s, client_ip=%s", cfg["endpoint"], cfg["client_ip"])
    return cfg


def _cleanup(workdir: str):
    """Tear down WireGuard interfaces, forwarding rules, and temp directory."""
    sh("ip link delete wg_main", check=False)
    sh("ip link delete wg_exit", check=False)
    sh("iptables -F FORWARD", check=False)
    sh("iptables -t nat -F POSTROUTING", check=False)
    sh("ip rule del from 10.0.1.0/24 to 10.0.1.0/24 table main priority 99", check=False)
    sh("ip rule del from 10.0.1.0/24 table 100 priority 100", check=False)
    sh("ip route flush table 100", check=False)
    if os.path.isdir(workdir):
        shutil.rmtree(workdir)


def _setup_main_server(workdir: str) -> dict:
    """Create wg_main — VPN server interface (10.0.1.1/24, listen :51821)."""
    from wireguard_go_bridge import WireGuardBridge
    from wireguard_go_bridge.keys import generate_private_key, derive_public_key
    log.info("Setting up wg_main")

    priv = generate_private_key()
    pub = derive_public_key(priv)
    db_path = os.path.join(workdir, "main.db")
    listen_port = 51821

    create_device_db(db_path)
    wg = WireGuardBridge(ifname="wg_main", mtu=1420, db_path=db_path)
    wg.ipc_set(f"private_key={priv}\nlisten_port={listen_port}\n")
    wg.up()
    sh("ip addr add 10.0.1.1/24 dev wg_main")
    sh("ip link set wg_main up")

    log.info("  wg_main: 10.0.1.1/24, listen=%d", listen_port)
    return {"wg": wg, "priv": priv, "pub": pub, "db_path": db_path}


def _setup_exit_client(workdir: str, exit_cfg: dict) -> dict:
    """Create wg_exit — exit tunnel client using provider-supplied config."""
    from wireguard_go_bridge import WireGuardBridge
    log.info("Setting up wg_exit (exit server config)")

    db_path = os.path.join(workdir, "exit.db")

    create_device_db(db_path)
    wg = WireGuardBridge(ifname="wg_exit", mtu=1420, db_path=db_path)
    wg.ipc_set(f"private_key={exit_cfg['client_priv_hex']}\n")

    ipc = f"public_key={exit_cfg['server_pub_hex']}\n"
    ipc += f"endpoint={exit_cfg['endpoint']}\n"
    ipc += f"allowed_ip={exit_cfg['allowed_ips']}\n"
    ipc += f"persistent_keepalive_interval=25\n"
    if exit_cfg["psk_hex"]:
        ipc += f"preshared_key={exit_cfg['psk_hex']}\n"
    wg.ipc_set(ipc)

    wg.up()
    sh(f"ip addr add {exit_cfg['client_ip']} dev wg_exit")
    sh("ip link set wg_exit up")

    log.info("  wg_exit: %s → %s", exit_cfg["client_ip"], exit_cfg["endpoint"])
    return {"wg": wg, "priv_hex": exit_cfg["client_priv_hex"],
            "server_pub_hex": exit_cfg["server_pub_hex"], "db_path": db_path}


def _setup_multihop_forwarding():
    """Set up policy routing + iptables for wg_main → wg_exit forwarding."""
    log.info("Setting up multihop forwarding")
    sh("sysctl -w net.ipv4.ip_forward=1")
    sh("ip rule add from 10.0.1.0/24 to 10.0.1.0/24 table main priority 99")
    sh("ip rule add from 10.0.1.0/24 table 100 priority 100")
    sh("ip route add default dev wg_exit table 100")
    sh("iptables -A FORWARD -i wg_main -o wg_exit -j ACCEPT")
    sh("iptables -A FORWARD -i wg_exit -o wg_main -m state --state RELATED,ESTABLISHED -j ACCEPT")
    sh("iptables -t nat -A POSTROUTING -s 10.0.1.0/24 -o wg_exit -j MASQUERADE")
    log.info("  wg_main(10.0.1.0/24) → table 100 → wg_exit")


def _cleanup_forwarding():
    """Remove forwarding rules (iptables flush + policy routing table 100)."""
    sh("iptables -F FORWARD", check=False)
    sh("iptables -t nat -F POSTROUTING", check=False)
    sh("ip rule del from 10.0.1.0/24 to 10.0.1.0/24 table main priority 99", check=False)
    sh("ip rule del from 10.0.1.0/24 table 100 priority 100", check=False)
    sh("ip route flush table 100", check=False)


def _restart_bridge(main_db: str, exit_db: str, exit_cfg: dict) -> tuple:
    """Recreate both devices from SQLite state — simulates crash recovery."""
    from wireguard_go_bridge import WireGuardBridge
    log.info("Restarting bridge from DB")

    sh("ip link delete wg_main", check=False)
    sh("ip link delete wg_exit", check=False)

    wg_main = WireGuardBridge(ifname="wg_main", mtu=1420, db_path=main_db)
    wg_main.up()
    sh("ip addr add 10.0.1.1/24 dev wg_main")
    sh("ip link set wg_main up")

    wg_exit = WireGuardBridge(ifname="wg_exit", mtu=1420, db_path=exit_db)
    wg_exit.up()
    sh(f"ip addr add {exit_cfg['client_ip']} dev wg_exit")
    sh("ip link set wg_exit up")

    _setup_multihop_forwarding()
    log.info("  Bridge restored from DB")
    return wg_main, wg_exit


def _ping(target: str) -> bool:
    """Send 3 ICMP pings with 2s timeout. Returns True if target responds."""
    r = sh(f"ping -c3 -W2 {target}", check=False)
    return r.returncode == 0


def _verify_db(db_path: str, key: str, label: str):
    """Assert persisted IPC dump in DB contains the expected key string."""
    conn = sqlite3.connect(db_path)
    row = conn.execute("SELECT dump FROM ipc_state WHERE id = 1").fetchone()
    conn.close()
    assert row is not None, f"{label}: no state in DB"
    assert key in row[0], f"{label}: key missing from dump"
    log.info("  DB OK: %s (%d bytes)", label, len(row[0]))


class TestExitTunnel:

    def test_full_lifecycle(self):
        """Full lifecycle: tunnel up, crash recovery from DB, client multihop.

        Phase 1: Tunnel establishment — wg_main + wg_exit, ping exit
        Phase 2: Crash + recovery — close devices, 10s wait, reopen from DB
        Phase 3: Client connects — wg-quick via Docker socket, ping through bridge
        """
        workdir = tempfile.mkdtemp(prefix="wg-bridge-test-")
        try:
            exit_cfg = _get_exit_config()

            # ---- Phase 1: Tunnel establishment ----
            log.info("=" * 60)
            log.info("PHASE 1: Tunnel establishment")
            log.info("=" * 60)

            main = _setup_main_server(workdir)
            exit_client = _setup_exit_client(workdir, exit_cfg)
            _setup_multihop_forwarding()

            log.info("Waiting for handshake...")
            time.sleep(5)

            assert _ping("10.0.1.1"), "wg_main not reachable"
            assert _ping("10.0.2.1"), "exit not reachable"

            _verify_db(main["db_path"], main["priv"], "wg_main")
            _verify_db(exit_client["db_path"], exit_client["priv_hex"], "wg_exit")

            log.info("PHASE 1 PASSED")

            # ---- Phase 2: Crash + recovery ----
            log.info("=" * 60)
            log.info("PHASE 2: Bridge crash + recovery")
            log.info("=" * 60)

            main["wg"].close()
            exit_client["wg"].close()
            _cleanup_forwarding()

            assert not _ping("10.0.2.1"), "should be down"
            log.info("  Tunnel down confirmed")

            log.info("  Waiting 10 seconds...")
            time.sleep(10)

            wg_main, wg_exit = _restart_bridge(
                main["db_path"], exit_client["db_path"], exit_cfg)

            log.info("Waiting for re-handshake...")
            time.sleep(5)

            assert _ping("10.0.1.1"), "wg_main recovery failed"
            assert _ping("10.0.2.1"), "exit recovery failed"

            exit_state = wg_exit.ipc_get()
            assert exit_client["server_pub_hex"] in exit_state, "exit peer not restored"
            main_state = wg_main.ipc_get()
            assert main["priv"] in main_state, "main key not restored"

            log.info("PHASE 2 PASSED")

            # ---- Phase 3: Client connects ----
            log.info("=" * 60)
            log.info("PHASE 3: Client connects through bridge")
            log.info("=" * 60)

            from wireguard_go_bridge.keys import (
                generate_private_key, derive_public_key, hex_to_base64,
                generate_preshared_key,
            )

            client_priv = generate_private_key()
            client_pub = derive_public_key(client_priv)
            client_psk = generate_preshared_key()

            wg_main.ipc_set(
                f"public_key={client_pub}\n"
                f"preshared_key={client_psk}\n"
                f"allowed_ip=10.0.1.2/32\n"
                f"persistent_keepalive_interval=25\n"
            )
            log.info("  Client peer added to wg_main")

            main_pub_b64 = hex_to_base64(main["pub"])
            client_priv_b64 = hex_to_base64(client_priv)
            client_psk_b64 = hex_to_base64(client_psk)
            # hostname -i returns every address; on a dual-stack docker
            # network that is "fd.. 172...", which corrupts Endpoint.
            # The tunnel here runs over v4 — take the first v4 address.
            addrs = subprocess.run(
                "hostname -i", shell=True, capture_output=True, text=True
            ).stdout.split()
            bridge_ip = next(a for a in addrs if "." in a)

            client_conf = (
                f"[Interface]\n"
                f"PrivateKey = {client_priv_b64}\n"
                f"Address = 10.0.1.2/24\n"
                f"\n"
                f"[Peer]\n"
                f"PublicKey = {main_pub_b64}\n"
                f"PresharedKey = {client_psk_b64}\n"
                f"AllowedIPs = 10.0.1.0/24, 10.0.2.0/24\n"
                f"Endpoint = {bridge_ip}:{51821}\n"
                f"PersistentKeepalive = 1\n"
            )
            log.info("  Client config:\n%s", client_conf)

            client_write_file("/etc/wireguard/wg0.conf", client_conf)
            client_exec("wg-quick up wg0")

            log.info("Waiting for client handshake...")
            time.sleep(5)

            rc, _ = client_exec("ping -c3 -W2 10.0.1.1", check=False)
            assert rc == 0, "client→wg_main failed"

            rc, _ = client_exec("ping -c3 -W2 10.0.2.1", check=False)
            assert rc == 0, "client→exit failed"

            client_exec("wg show wg0", check=False)

            wg_main.close()
            wg_exit.close()

            log.info("PHASE 3 PASSED")
            log.info("=" * 60)
            log.info("ALL PHASES PASSED")
            log.info("=" * 60)

        finally:
            _cleanup(workdir)