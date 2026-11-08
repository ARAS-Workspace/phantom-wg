"""Tests for phantom_daemon.base.exit_store.render — stored exit to .conf text."""

from __future__ import annotations

import os

import pytest

from phantom_daemon.base.exit_store.parser import parse_wireguard_config
from phantom_daemon.base.exit_store.render import render_wireguard_config

_FIELDS = (
    "private_key_hex", "address", "public_key_hex", "preshared_key_hex",
    "endpoint", "allowed_ips", "keepalive",
)


def _exit(**overrides: str | int) -> dict:
    """A stored exit as the store returns it, with fresh random keys."""
    data: dict = {
        "id": "0" * 32,
        "name": "exit-1",
        "endpoint": "203.0.113.10:51820",
        "address": "10.66.0.2/32",
        "private_key_hex": os.urandom(32).hex(),
        "public_key_hex": os.urandom(32).hex(),
        "preshared_key_hex": os.urandom(32).hex(),
        "allowed_ips": "0.0.0.0/0, ::/0",
        "keepalive": 25,
    }
    data.update(overrides)
    return data


class TestRenderOutput:
    def test_full_text(self):
        data = _exit(
            private_key_hex="aa" * 32,
            public_key_hex="bb" * 32,
            preshared_key_hex="cc" * 32,
        )
        assert render_wireguard_config(data) == (
            "[Interface]\n"
            "PrivateKey = qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo=\n"
            "Address = 10.66.0.2/32\n"
            "\n"
            "[Peer]\n"
            "PublicKey = u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7s=\n"
            "PresharedKey = zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMw=\n"
            "Endpoint = 203.0.113.10:51820\n"
            "AllowedIPs = 0.0.0.0/0, ::/0\n"
            "PersistentKeepalive = 25\n"
        )


class TestRoundTrip:
    @pytest.mark.parametrize("overrides", [
        pytest.param({}, id="psk"),
        pytest.param({"preshared_key_hex": ""}, id="no-psk"),
        pytest.param({"keepalive": 0}, id="keepalive-0"),
        pytest.param({"keepalive": 65535}, id="keepalive-max"),
        pytest.param(
            {"allowed_ips": "10.0.0.0/8, 192.168.0.0/16, fd00::/64"},
            id="allowed-ips-many",
        ),
        pytest.param({"endpoint": "[2001:db8::1]:51820"}, id="endpoint-ipv6"),
        pytest.param({"endpoint": "vpn.example.com:51820"}, id="endpoint-hostname"),
        pytest.param({"address": "10.66.0.2/32, fd66::2/128"}, id="address-many"),
    ])
    def test_parse_returns_stored_fields(self, overrides):
        data = _exit(**overrides)
        parsed = parse_wireguard_config(render_wireguard_config(data))
        assert {f: getattr(parsed, f) for f in _FIELDS} == {f: data[f] for f in _FIELDS}
