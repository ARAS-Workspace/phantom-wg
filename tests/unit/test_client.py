"""Tests for Wallet client CRUD — assign, revoke, get, list."""

from __future__ import annotations

import pytest

from phantom_daemon.base.errors import WalletError
from phantom_daemon.base.wallet import create_wallet

# ── Assign ────────────────────────────────────────────────────────


class TestAssignClient:
    def test_assign_returns_dict(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            client = w.assign_client("alice")
            assert isinstance(client, dict)
            for key in (
                "id", "name", "ipv4_address", "ipv6_address",
                "private_key_hex", "public_key_hex", "preshared_key_hex",
                "created_at", "updated_at",
            ):
                assert key in client

    def test_assign_fills_first_slot(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            client = w.assign_client("alice")
            assert client["ipv4_address"] == "10.8.0.2"
            assert client["ipv6_address"] == "fd00:70:68::2"

    def test_assign_increments(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            w.assign_client("alice")
            bob = w.assign_client("bob")
            assert bob["ipv4_address"] == "10.8.0.3"

    def test_assign_duplicate_name(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            w.assign_client("alice")
            with pytest.raises(WalletError, match="already exists"):
                w.assign_client("alice")

    def test_assign_generates_unique_id(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            a = w.assign_client("alice")
            b = w.assign_client("bob")
            assert a["id"] != b["id"]
            assert len(a["id"]) == 32  # uuid4 hex


# ── Revoke ────────────────────────────────────────────────────────


class TestRevokeClient:
    def test_revoke_frees_slot(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            w.assign_client("alice")
            free_before = w.count_free()
            w.revoke_client("alice")
            assert w.count_free() == free_before + 1

    def test_revoke_not_found(self, tmp_path):
        with (
            create_wallet(str(tmp_path)) as w,
            pytest.raises(WalletError, match="not found"),
        ):
            w.revoke_client("ghost")

    def test_revoke_then_reassign(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            client = w.assign_client("alice")
            original_ip = client["ipv4_address"]
            w.revoke_client("alice")
            # Freed slot should be reusable (first free = original IP)
            new_client = w.assign_client("alice2")
            assert new_client["ipv4_address"] == original_ip


# ── Get ───────────────────────────────────────────────────────────


class TestGetClient:
    def test_get_existing(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            w.assign_client("alice")
            client = w.get_client("alice")
            assert isinstance(client, dict)
            assert client["name"] == "alice"

    def test_get_nonexistent(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            assert w.get_client("ghost") is None


# ── List ──────────────────────────────────────────────────────────


class TestListClients:
    def test_list_empty(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            assert w.list_clients() == []

    def test_list_multiple(self, tmp_path):
        with create_wallet(str(tmp_path)) as w:
            w.assign_client("alice")
            w.assign_client("bob")
            w.assign_client("carol")
            clients = w.list_clients()
            assert len(clients) == 3
            names = [c["name"] for c in clients]
            assert names == ["alice", "bob", "carol"]
