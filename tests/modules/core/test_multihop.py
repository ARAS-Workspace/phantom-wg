"""Integration tests for /api/multihop error codes, update and config.

API call → response code and message check → exit store state verification.
Each test leaves the session exit store as it found it.
"""

from __future__ import annotations

import base64
import os

import pytest

from phantom_daemon.base.exit_store import parse_wireguard_config

EXIT_NAME = "mh-codes"

_FIELDS = (
    "private_key_hex", "address", "public_key_hex", "preshared_key_hex",
    "endpoint", "allowed_ips", "keepalive",
)


def _exit_conf(endpoint: str = "203.0.113.10:51820", keepalive: int | None = None) -> str:
    """A minimal valid exit config with fresh random keys."""
    private_key = base64.b64encode(os.urandom(32)).decode()
    public_key = base64.b64encode(os.urandom(32)).decode()
    conf = (
        "[Interface]\n"
        f"PrivateKey = {private_key}\n"
        "Address = 10.66.0.2/32\n"
        "\n"
        "[Peer]\n"
        f"PublicKey = {public_key}\n"
        f"Endpoint = {endpoint}\n"
        "AllowedIPs = 0.0.0.0/0\n"
    )
    if keepalive is not None:
        conf += f"PersistentKeepalive = {keepalive}\n"
    return conf


def _import(client, name: str):
    return client.post(
        "/api/multihop/import", json={"name": name, "config": _exit_conf()}
    )


def _names(test_env) -> list[str]:
    return [e["name"] for e in test_env.exit_store.list_exits()]


@pytest.fixture()
def imported(client, test_env):
    """One imported exit, removed afterwards whatever state the test left it in."""
    before = _names(test_env)
    resp = _import(client, EXIT_NAME)
    assert resp.status_code == 201
    assert _names(test_env) == [*before, EXIT_NAME]

    yield EXIT_NAME

    store = test_env.exit_store
    if store.get_active() == EXIT_NAME:
        store.deactivate()
    if store.get_exit(EXIT_NAME) is not None:
        store.remove_exit(EXIT_NAME)
    assert _names(test_env) == before


class TestExitErrorCodes:

    def test_import_duplicate_name(self, client, test_env, imported):
        before = _names(test_env)

        resp = _import(client, imported)
        assert resp.status_code == 400
        body = resp.json()
        assert body["ok"] is False
        assert body["code"] == "EXIT_ALREADY_EXISTS"
        assert body["error"] == f"Exit name already exists: {imported}"

        # DB state — the first import is untouched
        assert _names(test_env) == before

    def test_remove_unknown(self, client, test_env):
        before = _names(test_env)

        resp = client.post("/api/multihop/remove", json={"name": "mh-missing"})
        assert resp.status_code == 404
        body = resp.json()
        assert body["ok"] is False
        assert body["code"] == "EXIT_NOT_FOUND"
        assert body["error"] == "Exit not found: mh-missing"

        # DB state
        assert _names(test_env) == before

    def test_remove_active(self, client, test_env, imported):
        test_env.exit_store.activate(imported)
        before = _names(test_env)

        resp = client.post("/api/multihop/remove", json={"name": imported})
        assert resp.status_code == 400
        body = resp.json()
        assert body["ok"] is False
        assert body["code"] == "EXIT_IS_ACTIVE"
        assert body["error"] == f"Cannot remove active exit: {imported} — deactivate first"

        # DB state — still stored, still active
        assert _names(test_env) == before
        assert test_env.exit_store.get_active() == imported

    def test_remove_inactive(self, client, test_env, imported):
        before = _names(test_env)

        resp = client.post("/api/multihop/remove", json={"name": imported})
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is True
        assert body["data"] == {"status": "removed", "code": "EXIT_REMOVED"}

        # DB state
        assert _names(test_env) == [n for n in before if n != imported]


class TestExitUpdateAndConfig:

    def test_config_round_trip(self, client, test_env, imported):
        resp = client.post("/api/multihop/config", json={"name": imported})
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is True

        # The text parses back to exactly what is stored, keys included
        parsed = parse_wireguard_config(body["data"])
        stored = test_env.exit_store.get_exit(imported)
        assert {f: getattr(parsed, f) for f in _FIELDS} == {f: stored[f] for f in _FIELDS}

    def test_config_unknown(self, client):
        resp = client.post("/api/multihop/config", json={"name": "mh-missing"})
        assert resp.status_code == 404
        body = resp.json()
        assert body["ok"] is False
        assert body["code"] == "EXIT_NOT_FOUND"
        assert body["error"] == "Exit not found: mh-missing"

    def test_update_valid(self, client, test_env, imported):
        before = test_env.exit_store.list_exits()
        conf = _exit_conf(endpoint="198.51.100.20:51821", keepalive=15)

        resp = client.post("/api/multihop/update", json={"name": imported, "config": conf})
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is True
        data = body["data"]
        assert data["name"] == imported
        assert data["endpoint"] == "198.51.100.20:51821"
        assert data["keepalive"] == 15
        assert "private_key_hex" not in data

        # DB state — new values, same id, same position
        parsed = parse_wireguard_config(conf)
        stored = test_env.exit_store.get_exit(imported)
        assert {f: stored[f] for f in _FIELDS} == {f: getattr(parsed, f) for f in _FIELDS}
        after = test_env.exit_store.list_exits()
        assert [(e["id"], e["name"]) for e in after] == [(e["id"], e["name"]) for e in before]
        assert data["id"] == stored["id"]

    def test_update_invalid_config(self, client, test_env, imported):
        before = test_env.exit_store.get_exit(imported)

        resp = client.post(
            "/api/multihop/update", json={"name": imported, "config": "not a valid config"}
        )
        assert resp.status_code == 400
        body = resp.json()
        assert body["ok"] is False
        assert body["code"] == "INVALID_EXIT_CONFIG"
        assert body["error"] == "Line 1 is not a section header or key = value"

        # DB state — unchanged
        assert test_env.exit_store.get_exit(imported) == before

    def test_update_unknown(self, client, test_env):
        before = _names(test_env)

        resp = client.post(
            "/api/multihop/update", json={"name": "mh-missing", "config": _exit_conf()}
        )
        assert resp.status_code == 404
        body = resp.json()
        assert body["ok"] is False
        assert body["code"] == "EXIT_NOT_FOUND"
        assert body["error"] == "Exit not found: mh-missing"

        # DB state
        assert _names(test_env) == before

    def test_update_active(self, client, test_env, imported):
        test_env.exit_store.activate(imported)
        before = test_env.exit_store.get_exit(imported)

        resp = client.post(
            "/api/multihop/update", json={"name": imported, "config": _exit_conf()}
        )
        assert resp.status_code == 400
        body = resp.json()
        assert body["ok"] is False
        assert body["code"] == "EXIT_IS_ACTIVE"
        assert body["error"] == f"Cannot update active exit: {imported} — deactivate first"

        # DB state — unchanged, still active
        assert test_env.exit_store.get_exit(imported) == before
        assert test_env.exit_store.get_active() == imported
