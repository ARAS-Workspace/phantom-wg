"""Tests for phantom_daemon.base.wallet — database lifecycle and IP pool."""

from __future__ import annotations

import json
import sqlite3

import pytest

from phantom_daemon.base.errors import WalletError
from phantom_daemon.base.wallet import Wallet, _calculate_terazi, open_wallet

# ── Terazi ───────────────────────────────────────────────────────


class TestTerazi:
    def test_slash_24(self):
        v4, v6, capacity, host_bits = _calculate_terazi("10.8.0.0/24")
        assert v4 == "10.8.0.0/24"
        assert v6 == "fd00:70:68::/120"
        assert host_bits == 8
        assert capacity == 253  # 256 - 3

    def test_slash_22(self):
        v4, v6, capacity, host_bits = _calculate_terazi("10.8.0.0/22")
        assert v4 == "10.8.0.0/22"
        assert v6 == "fd00:70:68::/118"
        assert host_bits == 10
        assert capacity == 1021  # 1024 - 3


# ── Wallet creation ──────────────────────────────────────────────


class TestWalletCreate:
    def test_creates_tables(self, tmp_path):
        with open_wallet(str(tmp_path)) as w:
            assert isinstance(w, Wallet)
            assert w.count_users() > 0

    def test_config_defaults(self, tmp_path):
        with open_wallet(str(tmp_path)) as w:
            cfg = w.get_all_config()
            assert cfg["ipv4_subnet"] == "10.8.0.0/24"
            assert cfg["ipv6_subnet"] == "fd00:70:68::/120"
            dns_v4 = json.loads(cfg["dns_v4"])
            assert dns_v4 == {"primary": "9.9.9.9", "secondary": "149.112.112.112"}
            dns_v6 = json.loads(cfg["dns_v6"])
            assert dns_v6 == {"primary": "2620:fe::fe", "secondary": "2620:fe::9"}
            assert "interface_name" not in cfg

    def test_get_config_single(self, tmp_path):
        with open_wallet(str(tmp_path)) as w:
            raw = w.get_config("dns_v4")
            assert raw == json.dumps({"primary": "9.9.9.9", "secondary": "149.112.112.112"})
            assert w.get_config("nonexistent") is None

    def test_ip_pool_count(self, tmp_path):
        with open_wallet(str(tmp_path)) as w:
            # /24 → 253 usable IPs (index 2..254)
            assert w.count_users() == 253

    def test_ip_pool_first_last(self, tmp_path):
        with open_wallet(str(tmp_path)) as w:
            # noinspection SqlNoDataSourceInspection
            rows = w._conn.execute(
                "SELECT ipv4_address, ipv6_address FROM users "
                "ORDER BY rowid "
            ).fetchall()
            # First usable IP (index 2)
            assert rows[0] == ("10.8.0.2", "fd00:70:68::2")
            # Last usable IP (index 254)
            assert rows[-1] == ("10.8.0.254", "fd00:70:68::fe")

    def test_no_assigned_on_fresh_db(self, tmp_path):
        with open_wallet(str(tmp_path)) as w:
            assert w.count_assigned() == 0


# ── Wallet open ──────────────────────────────────────────────────


class TestWalletOpen:
    def test_reopen_existing(self, tmp_path):
        # Create
        w1 = open_wallet(str(tmp_path))
        w1.close()
        # Reopen
        with open_wallet(str(tmp_path)) as w2:
            assert w2.count_users() == 253
            raw = w2.get_config("dns_v4")
            assert raw == json.dumps({"primary": "9.9.9.9", "secondary": "149.112.112.112"})

    def test_missing_dir_raises(self):
        with pytest.raises(WalletError, match="does not exist"):
            open_wallet("/nonexistent/path")


# ── Context manager ──────────────────────────────────────────────


class TestWalletContextManager:
    def test_context_manager_closes(self, tmp_path):
        with open_wallet(str(tmp_path)) as w:
            w.count_users()
        # After exit, connection should be closed
        with pytest.raises(sqlite3.ProgrammingError, match="closed database"):
            w.count_users()


# ── Paginated client list ─────────────────────────────────────────


class TestListClientsPaginated:
    """Tests for wallet.list_clients_paginated()."""

    @pytest.fixture()
    def wallet_with_clients(self, tmp_path):
        """Wallet pre-loaded with 30 assigned clients: page-001 .. page-030."""
        w = open_wallet(str(tmp_path))
        for i in range(1, 31):
            w.assign_client(f"page-{i:03d}")
        yield w
        w.close()

    def test_empty_returns_zero(self, tmp_path):
        with open_wallet(str(tmp_path)) as w:
            result = w.list_clients_paginated()
        assert result["total"] == 0
        assert result["clients"] == []
        assert result["page"] == 1
        assert result["pages"] == 1

    def test_basic_first_page(self, wallet_with_clients):
        result = wallet_with_clients.list_clients_paginated(page=1, limit=10)
        assert result["total"] == 30
        assert result["pages"] == 3
        assert len(result["clients"]) == 10

    def test_last_page_partial(self, wallet_with_clients):
        result = wallet_with_clients.list_clients_paginated(page=3, limit=10)
        assert result["total"] == 30
        assert len(result["clients"]) == 10

    def test_beyond_last_page_empty(self, wallet_with_clients):
        result = wallet_with_clients.list_clients_paginated(page=99, limit=10)
        assert result["total"] == 30
        assert result["clients"] == []

    def test_order_asc(self, wallet_with_clients):
        result = wallet_with_clients.list_clients_paginated(page=1, limit=5, order="asc")
        names = [c["name"] for c in result["clients"]]
        assert names == sorted(names)
        assert result["order"] == "asc"

    def test_order_desc(self, wallet_with_clients):
        result = wallet_with_clients.list_clients_paginated(page=1, limit=5, order="desc")
        names = [c["name"] for c in result["clients"]]
        assert names == sorted(names, reverse=True)
        assert result["order"] == "desc"

    def test_search_match(self, wallet_with_clients):
        result = wallet_with_clients.list_clients_paginated(search="page-01")
        # "page-01" matches page-010..019 only — page-001 does NOT contain "page-01" as substring
        assert result["total"] == 10
        for c in result["clients"]:
            assert "page-01" in c["name"]

    def test_search_no_match(self, wallet_with_clients):
        result = wallet_with_clients.list_clients_paginated(search="notexist")
        assert result["total"] == 0
        assert result["clients"] == []

    def test_total_with_limit_1(self, wallet_with_clients):
        result = wallet_with_clients.list_clients_paginated(page=1, limit=1)
        assert result["total"] == 30
        assert result["pages"] == 30
        assert len(result["clients"]) == 1
