"""Tests for phantom_daemon.base.services.wireguard.ipc — IPC pure functions."""

from __future__ import annotations

from wireguard_go_bridge.keys import derive_public_key, generate_private_key

from phantom_daemon.base.services.wireguard import (
    WG_INTERFACE_NAME,
    WG_INTERFACE_NAME_EXIT,
)
from phantom_daemon.base.services.wireguard.ipc import (
    build_exit_config,
    build_full_config,
    build_peer_config,
    build_peer_remove_config,
    build_server_config,
    parse_device_status,
    parse_ipc_peers,
)


class TestConstants:
    def test_interface_name(self):
        assert WG_INTERFACE_NAME == "wg_phantom_main"

    def test_interface_name_exit(self):
        assert WG_INTERFACE_NAME_EXIT == "wg_phantom_exit"

    def test_interface_name_type(self):
        assert isinstance(WG_INTERFACE_NAME, str)


class TestBuildServerConfig:
    def test_format(self):
        cfg = build_server_config("abcd1234", 51820)
        assert cfg == "private_key=abcd1234\nlisten_port=51820\n"

    def test_ends_with_newline(self):
        cfg = build_server_config("ff", 1234)
        assert cfg.endswith("\n")

    def test_contains_key_and_port(self):
        cfg = build_server_config("deadbeef", 9999)
        assert "private_key=deadbeef" in cfg
        assert "listen_port=9999" in cfg


class TestBuildPeerConfig:
    def test_dual_stack_allowed_ips(self):
        cfg = build_peer_config(
            public_key_hex="aabb",
            preshared_key_hex="ccdd",
            ipv4_address="10.8.0.2",
            ipv6_address="fd00:70:68::2",
            keepalive=25,
        )
        assert "allowed_ip=10.8.0.2/32" in cfg
        assert "allowed_ip=fd00:70:68::2/128" in cfg

    def test_keepalive(self):
        cfg = build_peer_config("a", "b", "1.2.3.4", "::1", 10)
        assert "persistent_keepalive_interval=10" in cfg

    def test_preshared_key(self):
        cfg = build_peer_config("a", "psk_hex", "1.2.3.4", "::1", 25)
        assert "preshared_key=psk_hex" in cfg

    def test_format_lines(self):
        cfg = build_peer_config("pub", "psk", "10.0.0.1", "fd00::1", 30)
        lines = cfg.strip().split("\n")
        assert len(lines) == 5


class TestBuildFullConfig:
    def test_empty_clients(self):
        cfg = build_full_config("key", 51820, [], 25)
        assert "private_key=key" in cfg
        assert "replace_peers=true" in cfg
        assert "public_key=" not in cfg

    def test_with_clients(self):
        clients = [
            {
                "public_key_hex": "pub1",
                "preshared_key_hex": "psk1",
                "ipv4_address": "10.8.0.2",
                "ipv6_address": "fd00::2",
            },
            {
                "public_key_hex": "pub2",
                "preshared_key_hex": "psk2",
                "ipv4_address": "10.8.0.3",
                "ipv6_address": "fd00::3",
            },
        ]
        cfg = build_full_config("skey", 51820, clients, 25)
        assert cfg.count("public_key=") == 2
        assert "public_key=pub1" in cfg
        assert "public_key=pub2" in cfg

    def test_replace_peers_before_peers(self):
        clients = [
            {
                "public_key_hex": "pub1",
                "preshared_key_hex": "psk1",
                "ipv4_address": "10.8.0.2",
                "ipv6_address": "fd00::2",
            },
        ]
        cfg = build_full_config("skey", 51820, clients, 25)
        rp_pos = cfg.index("replace_peers=true")
        pk_pos = cfg.index("public_key=pub1")
        assert rp_pos < pk_pos


class TestBuildPeerRemoveConfig:
    def test_format(self):
        cfg = build_peer_remove_config("deadbeef")
        assert cfg == "public_key=deadbeef\nremove=true\n"

    def test_ends_with_newline(self):
        cfg = build_peer_remove_config("abc")
        assert cfg.endswith("\n")

    def test_contains_remove(self):
        cfg = build_peer_remove_config("xyz")
        assert "remove=true" in cfg
        assert "public_key=xyz" in cfg


class TestParseIpcPeers:
    def test_empty(self):
        assert parse_ipc_peers("") == set()

    def test_server_only(self):
        ipc = "private_key=abc\nlisten_port=51820\n"
        assert parse_ipc_peers(ipc) == set()

    def test_single_peer(self):
        ipc = (
            "private_key=abc\n"
            "listen_port=51820\n"
            "public_key=peer1\n"
            "preshared_key=psk\n"
            "allowed_ip=10.8.0.2/32\n"
        )
        assert parse_ipc_peers(ipc) == {"peer1"}

    def test_multiple_peers(self):
        ipc = (
            "private_key=abc\n"
            "public_key=peer1\n"
            "allowed_ip=10.8.0.2/32\n"
            "public_key=peer2\n"
            "allowed_ip=10.8.0.3/32\n"
            "public_key=peer3\n"
            "allowed_ip=10.8.0.4/32\n"
        )
        assert parse_ipc_peers(ipc) == {"peer1", "peer2", "peer3"}


class TestParseDeviceStatus:
    """Tests for parse_device_status — full UAPI dump parser."""

    _SERVER_PRIV = generate_private_key()
    _SERVER_PUB = derive_public_key(_SERVER_PRIV)

    def test_empty_dump(self):
        ds = parse_device_status("")
        assert ds.public_key == ""
        assert ds.listen_port == 0
        assert ds.fwmark == 0
        assert ds.peers == []

    def test_server_only_no_peers(self):
        ipc = (
            f"private_key={self._SERVER_PRIV}\n"
            "listen_port=51820\n"
            "fwmark=0\n"
        )
        ds = parse_device_status(ipc)
        assert ds.public_key == self._SERVER_PUB
        assert ds.listen_port == 51820
        assert ds.fwmark == 0
        assert ds.peers == []

    def test_single_peer_all_fields(self):
        ipc = (
            f"private_key={self._SERVER_PRIV}\n"
            "listen_port=51820\n"
            "fwmark=0\n"
            "public_key=aabbccdd\n"
            "endpoint=1.2.3.4:51820\n"
            "allowed_ip=10.0.0.2/32\n"
            "allowed_ip=fd00::2/128\n"
            "last_handshake_time_sec=1700000000\n"
            "last_handshake_time_nsec=123456789\n"
            "rx_bytes=1024\n"
            "tx_bytes=2048\n"
            "persistent_keepalive_interval=25\n"
        )
        ds = parse_device_status(ipc)
        assert len(ds.peers) == 1
        p = ds.peers[0]
        assert p.public_key == "aabbccdd"
        assert p.endpoint == "1.2.3.4:51820"
        assert p.allowed_ips == ["10.0.0.2/32", "fd00::2/128"]
        assert p.latest_handshake == 1700000000
        assert p.rx_bytes == 1024
        assert p.tx_bytes == 2048
        assert p.keepalive == 25

    def test_multiple_peers(self):
        ipc = (
            f"private_key={self._SERVER_PRIV}\n"
            "listen_port=51820\n"
            "public_key=peer1\n"
            "allowed_ip=10.0.0.2/32\n"
            "allowed_ip=fd00::2/128\n"
            "rx_bytes=100\n"
            "tx_bytes=200\n"
            "public_key=peer2\n"
            "allowed_ip=10.0.0.3/32\n"
            "rx_bytes=300\n"
            "tx_bytes=400\n"
            "public_key=peer3\n"
            "endpoint=5.6.7.8:51820\n"
            "allowed_ip=10.0.0.4/32\n"
            "allowed_ip=fd00::4/128\n"
            "allowed_ip=192.168.1.0/24\n"
        )
        ds = parse_device_status(ipc)
        assert len(ds.peers) == 3
        assert ds.peers[0].public_key == "peer1"
        assert ds.peers[0].allowed_ips == ["10.0.0.2/32", "fd00::2/128"]
        assert ds.peers[1].public_key == "peer2"
        assert ds.peers[1].rx_bytes == 300
        assert ds.peers[2].public_key == "peer3"
        assert ds.peers[2].endpoint == "5.6.7.8:51820"
        assert len(ds.peers[2].allowed_ips) == 3

    def test_handshake_zero(self):
        ipc = (
            f"private_key={self._SERVER_PRIV}\n"
            "listen_port=51820\n"
            "public_key=peer_no_hs\n"
            "last_handshake_time_sec=0\n"
            "last_handshake_time_nsec=0\n"
        )
        ds = parse_device_status(ipc)
        assert ds.peers[0].latest_handshake == 0

    def test_unknown_keys_ignored(self):
        ipc = (
            f"private_key={self._SERVER_PRIV}\n"
            "listen_port=51820\n"
            "public_key=peer1\n"
            "protocol_version=1\n"
            "some_future_field=xyz\n"
            "allowed_ip=10.0.0.2/32\n"
        )
        ds = parse_device_status(ipc)
        assert len(ds.peers) == 1
        assert ds.peers[0].allowed_ips == ["10.0.0.2/32"]

    def test_peer_defaults(self):
        ipc = (
            f"private_key={self._SERVER_PRIV}\n"
            "listen_port=51820\n"
            "public_key=minimal\n"
        )
        ds = parse_device_status(ipc)
        p = ds.peers[0]
        assert p.endpoint == ""
        assert p.allowed_ips == []
        assert p.latest_handshake == 0
        assert p.rx_bytes == 0
        assert p.tx_bytes == 0
        assert p.keepalive == 0


class TestBuildExitConfig:
    """Tests for build_exit_config — client-mode IPC builder."""

    def test_basic_format(self):
        cfg = build_exit_config(
            private_key_hex="aabbccdd",
            peer_public_key_hex="11223344",
            peer_preshared_key_hex="55667788",
            endpoint="1.2.3.4:51820",
            allowed_ips="0.0.0.0/0",
            keepalive=25,
        )
        assert "private_key=aabbccdd" in cfg
        assert "replace_peers=true" in cfg
        assert "public_key=11223344" in cfg
        assert "preshared_key=55667788" in cfg
        assert "endpoint=1.2.3.4:51820" in cfg
        assert "allowed_ip=0.0.0.0/0" in cfg
        assert "persistent_keepalive_interval=25" in cfg

    def test_no_listen_port(self):
        cfg = build_exit_config("a", "b", "c", "1.2.3.4:51820", "0.0.0.0/0", 5)
        assert "listen_port" not in cfg

    def test_multiple_allowed_ips(self):
        cfg = build_exit_config(
            "a", "b", "", "1.2.3.4:51820", "0.0.0.0/0, ::/0", 5,
        )
        assert "allowed_ip=0.0.0.0/0" in cfg
        assert "allowed_ip=::/0" in cfg

    def test_empty_preshared_key_omitted(self):
        cfg = build_exit_config("a", "b", "", "1.2.3.4:51820", "0.0.0.0/0", 5)
        assert "preshared_key=" not in cfg

    def test_replace_peers_before_public_key(self):
        cfg = build_exit_config("a", "peer_pub", "psk", "1.2.3.4:51820", "0.0.0.0/0", 5)
        rp_pos = cfg.index("replace_peers=true")
        pk_pos = cfg.index("public_key=peer_pub")
        assert rp_pos < pk_pos

    def test_ends_with_newline(self):
        cfg = build_exit_config("a", "b", "", "1.2.3.4:51820", "0.0.0.0/0", 5)
        assert cfg.endswith("\n")
