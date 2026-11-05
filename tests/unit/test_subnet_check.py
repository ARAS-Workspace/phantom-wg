"""Tests for the subnet check tools/prod.sh runs at setup."""

from __future__ import annotations

import ipaddress

import pytest

from phantom_daemon.base.wallet import _calculate_terazi
from phantom_daemon.base.wallet.subnet_check import check_subnet, main

# ── Accepted ─────────────────────────────────────────────────────


class TestAccepted:
    @pytest.mark.parametrize(
        "value",
        [
            "10.9.0.0/24",
            "10.9.0.0/16",
            "10.9.0.0/30",
            "172.16.0.0/24",
            "172.31.255.0/24",
            "192.168.77.0/24",
        ],
    )
    def test_returns_the_subnet(self, value):
        assert check_subnet(value) == value

    def test_host_bits_are_normalised(self):
        assert check_subnet("10.50.0.5/24") == "10.50.0.0/24"

    @pytest.mark.parametrize("prefix", range(16, 31))
    def test_every_allowed_prefix_gives_equal_pools(self, prefix):
        v4, v6, capacity, _ = _calculate_terazi(check_subnet(f"10.9.0.0/{prefix}"))
        v4_net = ipaddress.ip_network(v4)
        v6_net = ipaddress.ip_network(v6)
        assert v4_net.num_addresses == v6_net.num_addresses
        assert capacity >= 1


# ── Refused ──────────────────────────────────────────────────────


class TestRefused:
    @pytest.mark.parametrize(
        "value",
        ["garbage", "", "10.9.0/24", "256.0.0.0/24", "010.9.0.0/24", "fd00::/120"],
    )
    def test_not_a_subnet(self, value):
        with pytest.raises(ValueError, match="not an IPv4 subnet"):
            check_subnet(value)

    @pytest.mark.parametrize(
        "value", ["10.9.0.0", "10.0.0.0/8", "10.8.0.0/15", "10.9.0.0/31", "10.9.0.0/32"]
    )
    def test_prefix_out_of_range(self, value):
        with pytest.raises(ValueError, match="/16 to /30"):
            check_subnet(value)

    @pytest.mark.parametrize(
        "value",
        ["8.8.8.0/24", "172.15.0.0/24", "172.32.0.0/24", "192.169.0.0/24", "127.0.0.0/24"],
    )
    def test_not_private(self, value):
        with pytest.raises(ValueError, match="private"):
            check_subnet(value)


# ── Command line ─────────────────────────────────────────────────


class TestMain:
    def test_valid_prints_the_subnet(self, capsys):
        assert main(["subnet_check", "10.50.0.5/24"]) == 0
        captured = capsys.readouterr()
        assert captured.out.strip() == "10.50.0.0/24"
        assert captured.err == ""

    def test_invalid_reports_on_stderr(self, capsys):
        assert main(["subnet_check", "8.8.8.0/24"]) == 1
        captured = capsys.readouterr()
        assert captured.out == ""
        assert "8.8.8.0/24" in captured.err

    def test_wrong_argument_count(self, capsys):
        assert main(["subnet_check"]) == 2
        assert "Usage" in capsys.readouterr().err
