"""Tests for phantom_daemon.base.exit_store.parser — WireGuard config parser."""

from __future__ import annotations

import base64
import os

import pytest

# noinspection PyProtectedMember
from phantom_daemon.base.exit_store.parser import (
    ParsedWireGuardConfig,
    _base64_to_hex,
    parse_wireguard_config,
)


# ── Helper ──────────────────────────────────────────────────────

def _make_key_b64() -> str:
    """Generate a random 32-byte key as base64."""
    return base64.b64encode(os.urandom(32)).decode()


def _make_conf(
    private_key: str | None = None,
    address: str = "10.0.0.2/32",
    public_key: str | None = None,
    preshared_key: str | None = None,
    endpoint: str = "vpn.example.com:51820",
    allowed_ips: str = "0.0.0.0/0, ::/0",
    keepalive: int | None = 25,
) -> str:
    """Build a minimal WireGuard .conf string."""
    priv = private_key or _make_key_b64()
    pub = public_key or _make_key_b64()

    lines = [
        "[Interface]",
        f"PrivateKey = {priv}",
        f"Address = {address}",
        "",
        "[Peer]",
        f"PublicKey = {pub}",
    ]
    if preshared_key:
        lines.append(f"PresharedKey = {preshared_key}")
    lines.append(f"Endpoint = {endpoint}")
    lines.append(f"AllowedIPs = {allowed_ips}")
    if keepalive is not None:
        lines.append(f"PersistentKeepalive = {keepalive}")
    return "\n".join(lines)


# ── TestBase64ToHex ──────────────────────────────────────────────


class TestBase64ToHex:
    def test_valid_key(self):
        raw = os.urandom(32)
        b64 = base64.b64encode(raw).decode()
        assert _base64_to_hex(b64) == raw.hex()

    def test_length_32(self):
        b64 = _make_key_b64()
        hex_str = _base64_to_hex(b64)
        assert len(bytes.fromhex(hex_str)) == 32

    def test_short_key_raises(self):
        b64 = base64.b64encode(b"short").decode()
        with pytest.raises(ValueError, match="32 bytes"):
            _base64_to_hex(b64)

    def test_long_key_raises(self):
        b64 = base64.b64encode(os.urandom(64)).decode()
        with pytest.raises(ValueError, match="32 bytes"):
            _base64_to_hex(b64)


# ── TestParseWireGuardConfig ─────────────────────────────────────


class TestParseWireGuardConfig:
    def test_minimal_config(self):
        conf = _make_conf()
        result = parse_wireguard_config(conf)
        assert isinstance(result, ParsedWireGuardConfig)
        assert result.address == "10.0.0.2/32"
        assert result.endpoint == "vpn.example.com:51820"

    def test_private_key_hex(self):
        raw = os.urandom(32)
        priv_b64 = base64.b64encode(raw).decode()
        conf = _make_conf(private_key=priv_b64)
        result = parse_wireguard_config(conf)
        assert result.private_key_hex == raw.hex()

    def test_public_key_hex(self):
        raw = os.urandom(32)
        pub_b64 = base64.b64encode(raw).decode()
        conf = _make_conf(public_key=pub_b64)
        result = parse_wireguard_config(conf)
        assert result.public_key_hex == raw.hex()

    def test_preshared_key(self):
        raw = os.urandom(32)
        psk_b64 = base64.b64encode(raw).decode()
        conf = _make_conf(preshared_key=psk_b64)
        result = parse_wireguard_config(conf)
        assert result.preshared_key_hex == raw.hex()

    def test_no_preshared_key(self):
        conf = _make_conf()
        result = parse_wireguard_config(conf)
        assert result.preshared_key_hex == ""

    def test_allowed_ips(self):
        conf = _make_conf(allowed_ips="10.0.0.0/8, 192.168.0.0/16")
        result = parse_wireguard_config(conf)
        assert result.allowed_ips == "10.0.0.0/8, 192.168.0.0/16"

    def test_default_allowed_ips(self):
        """When AllowedIPs not in config, default to full tunnel."""
        priv = _make_key_b64()
        pub = _make_key_b64()
        conf = (
            "[Interface]\n"
            f"PrivateKey = {priv}\n"
            "Address = 10.0.0.2/32\n\n"
            "[Peer]\n"
            f"PublicKey = {pub}\n"
            "Endpoint = 1.2.3.4:51820\n"
        )
        result = parse_wireguard_config(conf)
        assert result.allowed_ips == "0.0.0.0/0, ::/0"

    def test_keepalive(self):
        conf = _make_conf(keepalive=15)
        result = parse_wireguard_config(conf)
        assert result.keepalive == 15

    def test_default_keepalive(self):
        conf = _make_conf(keepalive=None)
        result = parse_wireguard_config(conf)
        assert result.keepalive == 5

    def test_comments_ignored(self):
        priv = _make_key_b64()
        pub = _make_key_b64()
        conf = (
            "# This is a comment\n"
            "[Interface]\n"
            f"PrivateKey = {priv}\n"
            "Address = 10.0.0.2/32\n"
            "# Another comment\n\n"
            "[Peer]\n"
            f"PublicKey = {pub}\n"
            "Endpoint = 1.2.3.4:51820\n"
        )
        result = parse_wireguard_config(conf)
        assert result.address == "10.0.0.2/32"

    def test_frozen_dataclass(self):
        conf = _make_conf()
        result = parse_wireguard_config(conf)
        with pytest.raises(AttributeError):
            # noinspection PyDataclass
            result.address = "changed"


class TestParseWireGuardConfigErrors:
    def test_missing_private_key(self):
        pub = _make_key_b64()
        conf = (
            "[Interface]\n"
            "Address = 10.0.0.2/32\n\n"
            "[Peer]\n"
            f"PublicKey = {pub}\n"
            "Endpoint = 1.2.3.4:51820\n"
        )
        with pytest.raises(ValueError, match="PrivateKey"):
            parse_wireguard_config(conf)

    def test_missing_address(self):
        priv = _make_key_b64()
        pub = _make_key_b64()
        conf = (
            "[Interface]\n"
            f"PrivateKey = {priv}\n\n"
            "[Peer]\n"
            f"PublicKey = {pub}\n"
            "Endpoint = 1.2.3.4:51820\n"
        )
        with pytest.raises(ValueError, match="Address"):
            parse_wireguard_config(conf)

    def test_missing_public_key(self):
        priv = _make_key_b64()
        conf = (
            "[Interface]\n"
            f"PrivateKey = {priv}\n"
            "Address = 10.0.0.2/32\n\n"
            "[Peer]\n"
            "Endpoint = 1.2.3.4:51820\n"
        )
        with pytest.raises(ValueError, match="PublicKey"):
            parse_wireguard_config(conf)

    def test_missing_endpoint(self):
        priv = _make_key_b64()
        pub = _make_key_b64()
        conf = (
            "[Interface]\n"
            f"PrivateKey = {priv}\n"
            "Address = 10.0.0.2/32\n\n"
            "[Peer]\n"
            f"PublicKey = {pub}\n"
        )
        with pytest.raises(ValueError, match="Endpoint"):
            parse_wireguard_config(conf)

    def test_invalid_key(self):
        pub = _make_key_b64()
        conf = (
            "[Interface]\n"
            "PrivateKey = not-valid-base64!!!\n"
            "Address = 10.0.0.2/32\n\n"
            "[Peer]\n"
            f"PublicKey = {pub}\n"
            "Endpoint = 1.2.3.4:51820\n"
        )
        with pytest.raises((ValueError, UnicodeDecodeError)):
            parse_wireguard_config(conf)


# ── TestValidation ───────────────────────────────────────────────


class TestKeyErrorsAreQuiet:
    def test_key_never_appears_in_error(self):
        """Parser errors reach the HTTP body and the audit log — a length
        is enough to diagnose, the key material must not travel with it."""
        secret = base64.b64encode(b"eight123").decode()
        conf = _make_conf(private_key=secret)
        with pytest.raises(ValueError) as exc:
            parse_wireguard_config(conf)
        assert secret not in str(exc.value)
        assert "32 bytes" in str(exc.value)

    def test_names_the_field(self):
        conf = _make_conf(preshared_key=base64.b64encode(b"short").decode())
        with pytest.raises(ValueError, match=r"\[Peer\] PresharedKey"):
            parse_wireguard_config(conf)

    def test_non_alphabet_chars_rejected(self):
        """b64decode(validate=True) — otherwise garbage silently decodes."""
        with pytest.raises(ValueError, match="not valid base64"):
            _base64_to_hex("AAAA!!!!" + "A" * 36)


class TestAddressValidation:
    def test_invalid_cidr(self):
        with pytest.raises(ValueError, match=r"\[Interface\] Address"):
            parse_wireguard_config(_make_conf(address="not-an-ip"))

    def test_empty(self):
        with pytest.raises(ValueError, match=r"\[Interface\] Address is empty"):
            parse_wireguard_config(_make_conf(address="  "))

    def test_dual_stack_ok(self):
        result = parse_wireguard_config(
            _make_conf(address="10.0.0.2/24, fd10::2/64")
        )
        assert result.address == "10.0.0.2/24, fd10::2/64"


class TestAllowedIpsValidation:
    def test_space_separator_rejected(self):
        """The realistic typo: a space where a comma belongs. Before this
        check it reached the bridge as an opaque IpcError(-4) at enable."""
        with pytest.raises(ValueError, match=r"\[Peer\] AllowedIPs"):
            parse_wireguard_config(_make_conf(allowed_ips="0.0.0.0/0 ::/0"))

    def test_invalid_cidr(self):
        with pytest.raises(ValueError, match=r"\[Peer\] AllowedIPs"):
            parse_wireguard_config(_make_conf(allowed_ips="10.0.0.0/8, garbage"))

    def test_empty(self):
        with pytest.raises(ValueError, match=r"\[Peer\] AllowedIPs is empty"):
            parse_wireguard_config(_make_conf(allowed_ips="  "))


class TestEndpointValidation:
    def test_hostname_still_accepted(self):
        result = parse_wireguard_config(_make_conf(endpoint="vpn.example.com:51820"))
        assert result.endpoint == "vpn.example.com:51820"

    def test_bracketed_ipv6_accepted(self):
        result = parse_wireguard_config(_make_conf(endpoint="[2001:db8::1]:51820"))
        assert result.endpoint == "[2001:db8::1]:51820"

    def test_missing_port(self):
        with pytest.raises(ValueError, match="host:port"):
            parse_wireguard_config(_make_conf(endpoint="1.2.3.4"))

    def test_port_not_a_number(self):
        with pytest.raises(ValueError, match="port is not a number"):
            parse_wireguard_config(_make_conf(endpoint="1.2.3.4:https"))

    def test_port_out_of_range(self):
        with pytest.raises(ValueError, match="out of range"):
            parse_wireguard_config(_make_conf(endpoint="1.2.3.4:99999"))

    def test_bad_bracketed_ipv6(self):
        with pytest.raises(ValueError, match="IPv6 host is not valid"):
            parse_wireguard_config(_make_conf(endpoint="[not:an:ipv6]:51820"))

    def test_bracketed_ipv6_without_port(self):
        with pytest.raises(ValueError, match=r"\[ipv6\]:port"):
            parse_wireguard_config(_make_conf(endpoint="[2001:db8::1]"))

    def test_bare_ipv6_without_port_rejected(self):
        """rpartition would read this as host='2001:db8:' port=1 — in range,
        silently accepted, and wrong. Brackets are the only unambiguous form."""
        with pytest.raises(ValueError, match="multiple colons"):
            parse_wireguard_config(_make_conf(endpoint="2001:db8::1"))

    def test_bare_ipv6_with_port_rejected(self):
        """Genuinely ambiguous: '2001:db8::1:51820' is itself a valid IPv6
        address. WireGuard requires brackets for exactly this reason."""
        with pytest.raises(ValueError, match="multiple colons"):
            parse_wireguard_config(_make_conf(endpoint="2001:db8::1:51820"))

    def test_invalid_ipv4_literal_rejected(self):
        with pytest.raises(ValueError, match="IPv4 host is not valid"):
            parse_wireguard_config(_make_conf(endpoint="999.999.999.999:51820"))

    def test_octet_overflow_rejected(self):
        with pytest.raises(ValueError, match="IPv4 host is not valid"):
            parse_wireguard_config(_make_conf(endpoint="256.1.1.1:51820"))

    def test_hostname_family_is_not_inferred(self):
        """A hostname may resolve A, AAAA, or both, and that can change after
        import. The parser must not guess a family — DNS decides at dial time."""
        for host in ("vpn.example.com", "exit-1.mullvad.net", "localhost"):
            result = parse_wireguard_config(_make_conf(endpoint=f"{host}:51820"))
            assert result.endpoint == f"{host}:51820"


class TestKeepaliveValidation:
    def test_zero_is_valid(self):
        """0 disables keepalive — a legitimate value, not a missing one."""
        assert parse_wireguard_config(_make_conf(keepalive=0)).keepalive == 0

    def test_negative_rejected(self):
        with pytest.raises(ValueError, match="out of range"):
            parse_wireguard_config(_make_conf(keepalive=-5))

    def test_too_large_rejected(self):
        with pytest.raises(ValueError, match="out of range"):
            parse_wireguard_config(_make_conf(keepalive=99999))

    def test_not_a_number(self):
        conf = _make_conf().replace("PersistentKeepalive = 25",
                                    "PersistentKeepalive = soon")
        with pytest.raises(ValueError, match="not a number"):
            parse_wireguard_config(conf)
