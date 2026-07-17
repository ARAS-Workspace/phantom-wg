"""Tests for phantom_daemon.base.env — environment variable loading."""

from __future__ import annotations

import pytest

from phantom_daemon.base.env import DaemonEnv, load_env


class TestLoadEnv:
    def test_defaults(self, monkeypatch):
        # Clear all relevant env vars
        for var in (
            "PHANTOM_DB_DIR",
            "PHANTOM_STATE_DIR",
            "WIREGUARD_LISTEN_PORT",
            "WIREGUARD_MTU",
            "WIREGUARD_KEEPALIVE",
            "WIREGUARD_ENDPOINT_V4",
            "WIREGUARD_ENDPOINT_V6",
            "PHANTOM_LOG_LEVEL",
        ):
            monkeypatch.delenv(var, raising=False)

        env = load_env()
        assert env.db_dir == "/var/lib/phantom/db"
        assert env.state_dir == "/var/lib/phantom/state/db"
        assert env.listen_port == 51820
        assert env.mtu == 1420
        assert env.keepalive == 25
        assert env.endpoint_v4 == ""
        assert env.endpoint_v6 == ""
        assert env.log_level == "info"

    def test_custom_values(self, monkeypatch):
        monkeypatch.setenv("PHANTOM_DB_DIR", "/tmp/test-db")
        monkeypatch.setenv("PHANTOM_STATE_DIR", "/tmp/test-state")
        monkeypatch.setenv("WIREGUARD_LISTEN_PORT", "12345")
        monkeypatch.setenv("WIREGUARD_MTU", "1500")
        monkeypatch.setenv("WIREGUARD_KEEPALIVE", "10")
        monkeypatch.setenv("WIREGUARD_ENDPOINT_V4", "1.2.3.4")
        monkeypatch.setenv("WIREGUARD_ENDPOINT_V6", "::1")
        monkeypatch.setenv("PHANTOM_LOG_LEVEL", "debug")

        env = load_env()
        assert env.db_dir == "/tmp/test-db"
        assert env.state_dir == "/tmp/test-state"
        assert env.listen_port == 12345
        assert env.mtu == 1500
        assert env.keepalive == 10
        assert env.endpoint_v4 == "1.2.3.4"
        assert env.endpoint_v6 == "::1"
        assert env.log_level == "debug"

    def test_frozen(self, monkeypatch):
        for var in (
            "PHANTOM_DB_DIR",
            "PHANTOM_STATE_DIR",
            "WIREGUARD_LISTEN_PORT",
            "WIREGUARD_MTU",
            "WIREGUARD_KEEPALIVE",
            "WIREGUARD_ENDPOINT_V4",
            "WIREGUARD_ENDPOINT_V6",
            "PHANTOM_LOG_LEVEL",
        ):
            monkeypatch.delenv(var, raising=False)

        env = load_env()
        with pytest.raises(AttributeError):
            # noinspection PyDataclass
            env.db_dir = "/other"  # type: ignore[misc]

    def test_instance_type(self, monkeypatch):
        for var in (
            "PHANTOM_DB_DIR",
            "PHANTOM_STATE_DIR",
            "WIREGUARD_LISTEN_PORT",
            "WIREGUARD_MTU",
            "WIREGUARD_KEEPALIVE",
            "WIREGUARD_ENDPOINT_V4",
            "WIREGUARD_ENDPOINT_V6",
            "PHANTOM_LOG_LEVEL",
        ):
            monkeypatch.delenv(var, raising=False)

        env = load_env()
        assert isinstance(env, DaemonEnv)
