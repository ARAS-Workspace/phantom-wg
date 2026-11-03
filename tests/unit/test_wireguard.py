"""Tests for phantom_daemon.base.services.wireguard — real bridge, real wallet, no mocks."""

from __future__ import annotations

import hashlib
import os
import sqlite3
from pathlib import Path

import pytest

from phantom_daemon.base.errors import WireGuardError
from phantom_daemon.base.services.wireguard.ipc import parse_ipc_peers
from phantom_daemon.base.services.wireguard.service import (
    WireGuardService,
    _ensure_device_db,
    _split_addresses,
    open_wireguard,
)

# ── WG-specific helpers ──────────────────────────────────────────

_tag = hashlib.md5(os.urandom(8)).hexdigest()[:5]
_counter = 0


def _ifname() -> str:
    """Generate a unique interface name per test (IFNAMSIZ=16 safe)."""
    global _counter
    _counter += 1
    return f"wg_u_{_tag}{_counter:x}"


# ── TestSplitAddresses ──────────────────────────────────────────


class TestSplitAddresses:
    def test_single_ipv4(self):
        v4, v6 = _split_addresses("10.66.66.2/24")
        assert v4 == ["10.66.66.2/24"]
        assert v6 == []

    def test_single_ipv6(self):
        v4, v6 = _split_addresses("fd10:66:66::2/64")
        assert v4 == []
        assert v6 == ["fd10:66:66::2/64"]

    def test_dual_stack(self):
        v4, v6 = _split_addresses("10.66.66.2/24, fd10:66:66::2/64")
        assert v4 == ["10.66.66.2/24"]
        assert v6 == ["fd10:66:66::2/64"]

    def test_host_prefix_v4(self):
        v4, v6 = _split_addresses("10.0.0.2/32")
        assert v4 == ["10.0.0.2/32"]
        assert v6 == []

    def test_host_prefix_v6(self):
        v4, v6 = _split_addresses("fd10:66:66::2/128")
        assert v4 == []
        assert v6 == ["fd10:66:66::2/128"]

    def test_invalid_address_raises(self):
        with pytest.raises(ValueError):
            _split_addresses("not-an-address")

    def test_whitespace_tolerance(self):
        v4, v6 = _split_addresses("  10.0.0.1/24 ,  fd00::1/64  ")
        assert v4 == ["10.0.0.1/24"]
        assert v6 == ["fd00::1/64"]


# ── TestEnsureDeviceDb ───────────────────────────────────────────


class TestEnsureDeviceDb:
    def test_creates_db(self, test_env):
        db_path = _ensure_device_db(test_env.sub("ensure-create"))
        assert db_path.exists()
        assert db_path.name == "device.db"

    def test_idempotent(self, test_env):
        d = test_env.sub("ensure-idem")
        p1 = _ensure_device_db(d)
        p2 = _ensure_device_db(d)
        assert p1 == p2

    def test_schema_applied(self, test_env):
        db_path = _ensure_device_db(test_env.sub("ensure-schema"))
        conn = sqlite3.connect(str(db_path))
        tables = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
        conn.close()
        table_names = {t[0] for t in tables}
        assert "ipc_state" in table_names

    def test_missing_dir_raises(self):
        with pytest.raises(WireGuardError, match="State directory"):
            _ensure_device_db("/nonexistent/path/to/nowhere")


# ── TestOpenWireguard ────────────────────────────────────────────


class TestOpenWireguard:
    def test_missing_state_dir(self):
        with pytest.raises(WireGuardError, match="State directory"):
            open_wireguard(state_dir="/nonexistent", mtu=1420)

    def test_creates_service(self, test_env):
        d = test_env.sub("open-svc")
        svc = open_wireguard(state_dir=d, mtu=1420, ifname=_ifname())
        assert isinstance(svc, WireGuardService)
        svc.close()

    def test_device_db_created(self, test_env):
        d = test_env.sub("open-db")
        ifn = _ifname()
        svc = open_wireguard(state_dir=d, mtu=1420, ifname=ifn)
        assert (Path(d) / "wireguard" / ifn / "device.db").exists()
        svc.close()


# ── TestLifecycle ────────────────────────────────────────────────


class TestLifecycle:
    def test_up_down(self, test_env):
        d = test_env.sub("lifecycle")
        svc = open_wireguard(state_dir=d, mtu=1420, ifname=_ifname())
        svc.up()
        svc.down()
        svc.close()

    def test_context_manager(self, test_env):
        d = test_env.sub("ctx-mgr")
        with open_wireguard(state_dir=d, mtu=1420, ifname=_ifname()) as svc:
            svc.up()
            svc.down()


# ── TestFastSync ─────────────────────────────────────────────────


class TestFastSync:
    def test_empty_wallet_sync(self, test_env):
        """Empty wallet → IPC gets server config only, zero peers."""
        te = test_env
        d = te.sub("sync-empty")
        with open_wireguard(state_dir=d, mtu=te.env.mtu, ifname=_ifname()) as svc:
            w_count, i_count = svc.fast_sync(te.wallet, te.server_keys, te.env)
            assert w_count == 0
            assert i_count == 0

    def test_wallet_with_clients_sync(self, test_env):
        """Assign clients → fast_sync → IPC has those peers."""
        te = test_env
        d = te.sub("sync-clients")

        c1 = te.wallet.assign_client("wg_sync_alpha")
        c2 = te.wallet.assign_client("wg_sync_beta")

        with open_wireguard(state_dir=d, mtu=te.env.mtu, ifname=_ifname()) as svc:
            w_count, i_count = svc.fast_sync(te.wallet, te.server_keys, te.env)
            assert w_count >= 2
            assert i_count == 0

            ipc_out = svc._bridge.ipc_get()
            ipc_peers = parse_ipc_peers(ipc_out)
            assert c1["public_key_hex"] in ipc_peers
            assert c2["public_key_hex"] in ipc_peers

    def test_double_sync_idempotent(self, test_env):
        """Two consecutive fast_sync calls produce the same IPC state."""
        te = test_env
        d = te.sub("sync-double")
        with open_wireguard(state_dir=d, mtu=te.env.mtu, ifname=_ifname()) as svc:
            w1, _ = svc.fast_sync(te.wallet, te.server_keys, te.env)
            w2, i2 = svc.fast_sync(te.wallet, te.server_keys, te.env)
            assert w1 == w2
            assert i2 == w1

    def test_revoke_removes_from_ipc(self, test_env):
        """Revoke a client → fast_sync → peer disappears from IPC."""
        te = test_env
        d = te.sub("sync-revoke")

        c3 = te.wallet.assign_client("wg_sync_gamma")

        with open_wireguard(state_dir=d, mtu=te.env.mtu, ifname=_ifname()) as svc:
            svc.fast_sync(te.wallet, te.server_keys, te.env)
            ipc_before = parse_ipc_peers(svc._bridge.ipc_get())
            assert c3["public_key_hex"] in ipc_before

            te.wallet.revoke_client("wg_sync_gamma")
            svc.fast_sync(te.wallet, te.server_keys, te.env)

            ipc_after = parse_ipc_peers(svc._bridge.ipc_get())
            assert c3["public_key_hex"] not in ipc_after


# ── TestAddPeer ─────────────────────────────────────────────────


class TestAddPeer:
    def test_add_single_peer(self, test_env):
        """add_peer → peer appears in IPC."""
        te = test_env
        d = te.sub("add-single")
        _c = te.wallet.assign_client("wg_add_alpha")

        with open_wireguard(state_dir=d, mtu=te.env.mtu, ifname=_ifname()) as svc:
            svc.fast_sync(te.wallet, te.server_keys, te.env)
            peers_before = parse_ipc_peers(svc._bridge.ipc_get())

            c_new = te.wallet.assign_client("wg_add_beta")
            svc.add_peer(c_new, te.env.keepalive)

            peers_after = parse_ipc_peers(svc._bridge.ipc_get())
            assert c_new["public_key_hex"] in peers_after
            assert len(peers_after) == len(peers_before) + 1

    def test_add_preserves_existing(self, test_env):
        """add_peer does not disturb existing peers."""
        te = test_env
        d = te.sub("add-preserve")
        c1 = te.wallet.assign_client("wg_add_gamma")

        with open_wireguard(state_dir=d, mtu=te.env.mtu, ifname=_ifname()) as svc:
            svc.fast_sync(te.wallet, te.server_keys, te.env)

            c2 = te.wallet.assign_client("wg_add_delta")
            svc.add_peer(c2, te.env.keepalive)

            peers = parse_ipc_peers(svc._bridge.ipc_get())
            assert c1["public_key_hex"] in peers
            assert c2["public_key_hex"] in peers


# ── TestRemovePeer ──────────────────────────────────────────────


class TestRemovePeer:
    def test_remove_single_peer(self, test_env):
        """remove_peer → peer disappears from IPC."""
        te = test_env
        d = te.sub("rm-single")
        c = te.wallet.assign_client("wg_rm_alpha")

        with open_wireguard(state_dir=d, mtu=te.env.mtu, ifname=_ifname()) as svc:
            svc.fast_sync(te.wallet, te.server_keys, te.env)
            assert c["public_key_hex"] in parse_ipc_peers(svc._bridge.ipc_get())

            svc.remove_peer(c["public_key_hex"])
            assert c["public_key_hex"] not in parse_ipc_peers(svc._bridge.ipc_get())

    def test_remove_preserves_others(self, test_env):
        """remove_peer only removes the target, others stay."""
        te = test_env
        d = te.sub("rm-preserve")
        c1 = te.wallet.assign_client("wg_rm_beta")
        c2 = te.wallet.assign_client("wg_rm_gamma")

        with open_wireguard(state_dir=d, mtu=te.env.mtu, ifname=_ifname()) as svc:
            svc.fast_sync(te.wallet, te.server_keys, te.env)

            svc.remove_peer(c1["public_key_hex"])
            peers = parse_ipc_peers(svc._bridge.ipc_get())
            assert c1["public_key_hex"] not in peers
            assert c2["public_key_hex"] in peers

    def test_add_then_remove(self, test_env):
        """Runtime add → remove cycle without fast_sync."""
        te = test_env
        d = te.sub("add-rm-cycle")

        with open_wireguard(state_dir=d, mtu=te.env.mtu, ifname=_ifname()) as svc:
            svc.fast_sync(te.wallet, te.server_keys, te.env)
            peers_baseline = parse_ipc_peers(svc._bridge.ipc_get())

            c = te.wallet.assign_client("wg_rm_delta")
            svc.add_peer(c, te.env.keepalive)
            assert c["public_key_hex"] in parse_ipc_peers(svc._bridge.ipc_get())

            svc.remove_peer(c["public_key_hex"])
            peers_final = parse_ipc_peers(svc._bridge.ipc_get())
            assert c["public_key_hex"] not in peers_final
            assert len(peers_final) == len(peers_baseline)
