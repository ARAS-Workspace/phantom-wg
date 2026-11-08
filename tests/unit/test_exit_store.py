"""Tests for phantom_daemon.base.exit_store — store CRUD and state management."""

from __future__ import annotations

import pytest

from phantom_daemon.base.errors import (
    ExitActiveError,
    ExitAlreadyExistsError,
    ExitNotFoundError,
    ExitStoreError,
)
from phantom_daemon.base.exit_store.store import ExitStore, open_exit_store

_SAMPLE_EXIT = {
    "endpoint": "1.2.3.4:51820",
    "address": "10.0.0.2/32",
    "private_key_hex": "aa" * 32,
    "public_key_hex": "bb" * 32,
    "preshared_key_hex": "cc" * 32,
    "allowed_ips": "0.0.0.0/0, ::/0",
    "keepalive": 5,
}


class TestOpenExitStore:
    def test_missing_dir(self):
        with pytest.raises(ExitStoreError, match="does not exist"):
            open_exit_store(db_dir="/nonexistent/path/to/nowhere")

    def test_creates_store(self, test_env):
        d = test_env.sub("exit-open")
        store = open_exit_store(db_dir=d)
        assert isinstance(store, ExitStore)
        store.close()

    def test_reopen_existing(self, test_env):
        d = test_env.sub("exit-reopen")
        s1 = open_exit_store(db_dir=d)
        s1.add_exit("test1", **_SAMPLE_EXIT)
        s1.close()

        s2 = open_exit_store(db_dir=d)
        assert s2.get_exit("test1") is not None
        s2.close()


class TestContextManager:
    def test_with_statement(self, test_env):
        d = test_env.sub("exit-ctx")
        with open_exit_store(db_dir=d) as store:
            assert isinstance(store, ExitStore)


class TestDefaults:
    def test_not_enabled_by_default(self, test_env):
        d = test_env.sub("exit-defaults")
        with open_exit_store(db_dir=d) as store:
            assert store.is_enabled() is False

    def test_no_active_by_default(self, test_env):
        d = test_env.sub("exit-no-active")
        with open_exit_store(db_dir=d) as store:
            assert store.get_active() == ""


class TestAddExit:
    def test_add_returns_dict(self, test_env):
        d = test_env.sub("exit-add")
        with open_exit_store(db_dir=d) as store:
            result = store.add_exit("vpn1", **_SAMPLE_EXIT)
            assert result["name"] == "vpn1"
            assert result["endpoint"] == "1.2.3.4:51820"
            assert len(result["id"]) == 32

    def test_add_duplicate_raises(self, test_env):
        d = test_env.sub("exit-dup")
        with open_exit_store(db_dir=d) as store:
            store.add_exit("vpn1", **_SAMPLE_EXIT)
            with pytest.raises(ExitAlreadyExistsError, match="already exists"):
                store.add_exit("vpn1", **_SAMPLE_EXIT)

    def test_add_multiple(self, test_env):
        d = test_env.sub("exit-multi")
        with open_exit_store(db_dir=d) as store:
            store.add_exit("vpn1", **_SAMPLE_EXIT)
            store.add_exit("vpn2", **{**_SAMPLE_EXIT, "endpoint": "5.6.7.8:51820"})
            exits = store.list_exits()
            assert len(exits) == 2


class TestGetExit:
    def test_found(self, test_env):
        d = test_env.sub("exit-get")
        with open_exit_store(db_dir=d) as store:
            store.add_exit("vpn1", **_SAMPLE_EXIT)
            result = store.get_exit("vpn1")
            assert result is not None
            assert result["name"] == "vpn1"

    def test_not_found(self, test_env):
        d = test_env.sub("exit-get-nf")
        with open_exit_store(db_dir=d) as store:
            assert store.get_exit("nonexistent") is None


class TestListExits:
    def test_empty(self, test_env):
        d = test_env.sub("exit-list-empty")
        with open_exit_store(db_dir=d) as store:
            assert store.list_exits() == []

    def test_preserves_order(self, test_env):
        d = test_env.sub("exit-list-order")
        with open_exit_store(db_dir=d) as store:
            store.add_exit("aaa", **_SAMPLE_EXIT)
            store.add_exit("bbb", **{**_SAMPLE_EXIT, "endpoint": "5.6.7.8:51820"})
            names = [e["name"] for e in store.list_exits()]
            assert names == ["aaa", "bbb"]

    def test_no_private_key_leak_check(self, test_env):
        """Store returns private_key_hex — API layer filters it out."""
        d = test_env.sub("exit-list-pk")
        with open_exit_store(db_dir=d) as store:
            store.add_exit("vpn1", **_SAMPLE_EXIT)
            exits = store.list_exits()
            assert "private_key_hex" in exits[0]


class TestRemoveExit:
    def test_remove_success(self, test_env):
        d = test_env.sub("exit-rm")
        with open_exit_store(db_dir=d) as store:
            store.add_exit("vpn1", **_SAMPLE_EXIT)
            store.remove_exit("vpn1")
            assert store.get_exit("vpn1") is None

    def test_remove_not_found(self, test_env):
        d = test_env.sub("exit-rm-nf")
        with (
            open_exit_store(db_dir=d) as store,
            pytest.raises(ExitNotFoundError, match="not found"),
        ):
            store.remove_exit("nonexistent")

    def test_remove_active_raises(self, test_env):
        d = test_env.sub("exit-rm-active")
        with open_exit_store(db_dir=d) as store:
            store.add_exit("vpn1", **_SAMPLE_EXIT)
            store.activate("vpn1")
            with pytest.raises(ExitActiveError, match="deactivate first"):
                store.remove_exit("vpn1")


class TestActivateDeactivate:
    def test_activate(self, test_env):
        d = test_env.sub("exit-activate")
        with open_exit_store(db_dir=d) as store:
            store.add_exit("vpn1", **_SAMPLE_EXIT)
            store.activate("vpn1")
            assert store.is_enabled() is True
            assert store.get_active() == "vpn1"

    def test_activate_not_found(self, test_env):
        d = test_env.sub("exit-activate-nf")
        with (
            open_exit_store(db_dir=d) as store,
            pytest.raises(ExitNotFoundError, match="not found"),
        ):
            store.activate("nonexistent")

    def test_deactivate(self, test_env):
        d = test_env.sub("exit-deactivate")
        with open_exit_store(db_dir=d) as store:
            store.add_exit("vpn1", **_SAMPLE_EXIT)
            store.activate("vpn1")
            store.deactivate()
            assert store.is_enabled() is False
            assert store.get_active() == ""

    def test_switch_active(self, test_env):
        d = test_env.sub("exit-switch")
        with open_exit_store(db_dir=d) as store:
            store.add_exit("vpn1", **_SAMPLE_EXIT)
            store.add_exit("vpn2", **{**_SAMPLE_EXIT, "endpoint": "5.6.7.8:51820"})
            store.activate("vpn1")
            store.deactivate()
            store.activate("vpn2")
            assert store.get_active() == "vpn2"
