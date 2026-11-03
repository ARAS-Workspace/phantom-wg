"""Tests for phantom_daemon.base.services.wireguard.config — pure builder."""

from __future__ import annotations

import base64
import re

from wireguard_go_bridge.keys import (
    derive_public_key,
    generate_preshared_key,
    generate_private_key,
    hex_to_base64,
)

from phantom_daemon.base.services.wireguard.config import build_client_config

# ── Fixtures ──────────────────────────────────────────────────────

_CLIENT_PRIV = generate_private_key()
_CLIENT_PUB = derive_public_key(_CLIENT_PRIV)
_SERVER_PRIV = generate_private_key()
_SERVER_PUB = derive_public_key(_SERVER_PRIV)
_PSK = generate_preshared_key()

_DNS_V4 = {"primary": "9.9.9.9", "secondary": "149.112.112.112"}
_DNS_V6 = {"primary": "2620:fe::fe", "secondary": "2620:fe::9"}


def _build(version: str) -> str:
    return build_client_config(
        version=version,
        client_private_key_hex=_CLIENT_PRIV,
        client_ipv4="10.8.0.2",
        client_ipv6="fd00:70:68::2",
        server_public_key_hex=_SERVER_PUB,
        preshared_key_hex=_PSK,
        dns_v4=_DNS_V4,
        dns_v6=_DNS_V6,
        endpoint="vpn.example.com:51820",
        keepalive=25,
        mtu=1420,
    )


# ── Tests ─────────────────────────────────────────────────────────


class TestV4Config:
    def test_address_ipv4_only(self):
        conf = _build("v4")
        assert "Address = 10.8.0.2/32" in conf
        assert "fd00:70:68::2" not in conf

    def test_dns_v4_only(self):
        conf = _build("v4")
        assert "DNS = 9.9.9.9, 149.112.112.112" in conf
        assert "2620:fe" not in conf

    def test_allowed_ips_v4_only(self):
        conf = _build("v4")
        assert "AllowedIPs = 0.0.0.0/0" in conf
        assert "::/0" not in conf


class TestV6Config:
    def test_address_ipv6_only(self):
        conf = _build("v6")
        assert "Address = fd00:70:68::2/128" in conf
        assert "10.8.0.2" not in conf

    def test_dns_v6_only(self):
        conf = _build("v6")
        assert "DNS = 2620:fe::fe, 2620:fe::9" in conf
        assert "9.9.9.9" not in conf

    def test_allowed_ips_v6_only(self):
        conf = _build("v6")
        assert "AllowedIPs = ::/0" in conf
        assert "0.0.0.0/0" not in conf


class TestHybridConfig:
    def test_address_both(self):
        conf = _build("hybrid")
        assert "Address = 10.8.0.2/32, fd00:70:68::2/128" in conf

    def test_dns_both(self):
        conf = _build("hybrid")
        assert "DNS = 9.9.9.9, 149.112.112.112, 2620:fe::fe, 2620:fe::9" in conf

    def test_allowed_ips_both(self):
        conf = _build("hybrid")
        assert "AllowedIPs = 0.0.0.0/0, ::/0" in conf


class TestKeysAreBase64:
    def test_no_hex_keys_in_output(self):
        conf = _build("v4")
        # Hex keys are 64 chars, should NOT appear in output
        assert _CLIENT_PRIV not in conf
        assert _SERVER_PUB not in conf
        assert _PSK not in conf

    def test_base64_keys_present(self):
        conf = _build("v4")
        assert hex_to_base64(_CLIENT_PRIV) in conf
        assert hex_to_base64(_SERVER_PUB) in conf
        assert hex_to_base64(_PSK) in conf

    def test_keys_are_valid_base64(self):
        conf = _build("v4")
        key_pattern = re.compile(r"(?:PrivateKey|PublicKey|PresharedKey) = (.+)")
        matches = key_pattern.findall(conf)
        assert len(matches) == 3
        for key_b64 in matches:
            raw = base64.b64decode(key_b64)
            assert len(raw) == 32


class TestFormat:
    def test_trailing_newline(self):
        conf = _build("v4")
        assert conf.endswith("\n")

    def test_sections_present(self):
        conf = _build("v4")
        assert "[Interface]" in conf
        assert "[Peer]" in conf

    def test_endpoint(self):
        conf = _build("v4")
        assert "Endpoint = vpn.example.com:51820" in conf

    def test_keepalive(self):
        conf = _build("v4")
        assert "PersistentKeepalive = 25" in conf

    def test_mtu(self):
        conf = _build("v4")
        assert "MTU = 1420" in conf
