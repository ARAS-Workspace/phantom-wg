"""Tests for Wallet DNS configuration — get_dns, change_dns."""

from __future__ import annotations

import pytest

from phantom_daemon.base.errors import WalletError
from phantom_daemon.base.wallet import create_wallet

# ── get_dns ─────────────────────────────────────────────────────


class TestGetDns:
    def test_get_v4_defaults(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            dns = w.get_dns("v4")
            assert dns == {"primary": "9.9.9.9", "secondary": "149.112.112.112"}

    def test_get_v6_defaults(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            dns = w.get_dns("v6")
            assert dns == {"primary": "2620:fe::fe", "secondary": "2620:fe::9"}

    def test_get_invalid_family(self, tmp_path):
        with (
            create_wallet(str(tmp_path)) as w,
            pytest.raises(WalletError, match="Unknown DNS family"),
        ):
            w.get_dns("v8")


# ── change_dns ──────────────────────────────────────────────────


class TestChangeDns:
    def test_change_v4(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            w.change_dns("v4", "8.8.8.8", "8.8.4.4")
            dns = w.get_dns("v4")
            assert dns == {"primary": "8.8.8.8", "secondary": "8.8.4.4"}

    def test_change_v6(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            w.change_dns("v6", "2001:4860:4860::8888", "2001:4860:4860::8844")
            dns = w.get_dns("v6")
            assert dns == {
                "primary": "2001:4860:4860::8888",
                "secondary": "2001:4860:4860::8844",
            }

    def test_change_v6_normalises(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            # Uppercase + expanded → lowercase + compressed
            w.change_dns("v6", "2620:00FE:0000::00FE", "2620:00FE:0000::0009")
            dns = w.get_dns("v6")
            assert dns == {"primary": "2620:fe::fe", "secondary": "2620:fe::9"}

    def test_change_same_noop(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            w.change_dns("v4", "9.9.9.9", "149.112.112.112")
            # Should remain default (no-op)
            dns = w.get_dns("v4")
            assert dns == {"primary": "9.9.9.9", "secondary": "149.112.112.112"}

    def test_invalid_v4_address(self, tmp_path):
        with (
            create_wallet(str(tmp_path)) as w,
            pytest.raises(WalletError, match="Invalid IPv4 address"),
        ):
            w.change_dns("v4", "999.1.1.1", "8.8.4.4")

    def test_invalid_v6_address(self, tmp_path):
        with (
            create_wallet(str(tmp_path)) as w,
            pytest.raises(WalletError, match="Invalid IPv6 address"),
        ):
            w.change_dns("v6", "not::valid::ipv6::addr::x", "2620:fe::9")

    def test_invalid_family(self, tmp_path):
        with (
            create_wallet(str(tmp_path)) as w,
            pytest.raises(WalletError, match="Unknown DNS family"),
        ):
            w.change_dns("v8", "1.1.1.1", "1.0.0.1")

    def test_change_v4_then_v6(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            w.change_dns("v4", "8.8.8.8", "8.8.4.4")
            w.change_dns("v6", "2001:4860:4860::8888", "2001:4860:4860::8844")
            # v4 should still be Google
            dns_v4 = w.get_dns("v4")
            assert dns_v4 == {"primary": "8.8.8.8", "secondary": "8.8.4.4"}
            # v6 should be Google
            dns_v6 = w.get_dns("v6")
            assert dns_v6 == {
                "primary": "2001:4860:4860::8888",
                "secondary": "2001:4860:4860::8844",
            }
