"""Tests for Wallet subnet change and pool validation."""

from __future__ import annotations

import pytest

from phantom_daemon.base.errors import WalletError
from phantom_daemon.base.wallet import create_wallet

# ── Change CIDR ──────────────────────────────────────────────────


class TestChangeCidr:
    def test_expand_24_to_22(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            assert w.count_users() == 253
            w.change_cidr(22)
            assert w.count_users() == 1021

    def test_config_updated(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            w.change_cidr(22)
            assert w.get_config("ipv4_subnet") == "10.8.0.0/22"
            assert w.get_config("ipv6_subnet") == "fd00:70:68::/118"

    def test_clients_preserved(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            w.assign_client("alice")
            w.assign_client("bob")
            w.change_cidr(22)
            assert w.count_assigned() == 2

    def test_client_data_intact(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            original = w.assign_client("alice")
            w.change_cidr(22)
            restored = w.get_client("alice")
            assert restored["id"] == original["id"]
            assert restored["name"] == original["name"]
            assert restored["private_key_hex"] == original["private_key_hex"]
            assert restored["public_key_hex"] == original["public_key_hex"]
            assert restored["preshared_key_hex"] == original["preshared_key_hex"]

    def test_shrink_blocked(self, tmp_path):
        """Cannot shrink if assigned clients exceed new capacity."""
        with create_wallet(str(tmp_path)) as w:
            # /24 has 253 slots, assign enough to block /28 (13 slots)
            for i in range(14):
                w.assign_client(f"client-{i}")
            with pytest.raises(WalletError, match="slots"):
                w.change_cidr(28)

    def test_same_subnet_noop(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            w.assign_client("alice")
            w.change_cidr(24)  # same as default → no-op
            assert w.count_users() == 253
            assert w.get_client("alice") is not None


# ── Validate Pool ─────────────────────────────────────────────────


class TestValidatePool:
    def test_fresh_pool_valid(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            assert w.validate_pool() == []

    def test_valid_after_expand(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            w.change_cidr(22)
            assert w.validate_pool() == []
