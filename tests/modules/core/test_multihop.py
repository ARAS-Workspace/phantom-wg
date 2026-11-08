"""Integration tests for /api/multihop error codes.

API call → response code and message check → exit store state verification.
Each test leaves the session exit store as it found it.
"""

from __future__ import annotations

import base64
import os

import pytest

EXIT_NAME = "mh-codes"


def _exit_conf() -> str:
    """A minimal valid exit config with fresh random keys."""
    private_key = base64.b64encode(os.urandom(32)).decode()
    public_key = base64.b64encode(os.urandom(32)).decode()
    return (
        "[Interface]\n"
        f"PrivateKey = {private_key}\n"
        "Address = 10.66.0.2/32\n"
        "\n"
        "[Peer]\n"
        f"PublicKey = {public_key}\n"
        "Endpoint = 203.0.113.10:51820\n"
        "AllowedIPs = 0.0.0.0/0\n"
    )


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
