"""Integration tests for /api/core/clients endpoints.

API call → response check → DB state exact verification.
Tests are ordered via pytest-dependency within the class.
"""

from __future__ import annotations

import base64

import pytest
from starlette.testclient import TestClient
from wireguard_go_bridge.keys import hex_to_base64

from phantom_daemon.base.env import DaemonEnv
from phantom_daemon.main import create_app


class TestClientEndpoints:

    @pytest.mark.dependency()
    def test_assign_first(self, client, test_env):
        resp = client.post("/api/core/clients/assign", json={"name": "alice"})
        assert resp.status_code == 201
        body = resp.json()
        assert body["ok"] is True
        data = body["data"]
        assert data["name"] == "alice"
        assert "ipv4_address" in data
        assert "private_key_hex" in data
        assert "preshared_key_hex" in data
        assert "created_at" in data

        # DB state
        db = test_env.wallet.get_client("alice")
        assert db is not None
        assert db["name"] == "alice"
        assert db["ipv4_address"] == data["ipv4_address"]
        assert db["ipv6_address"] == data["ipv6_address"]
        assert db["private_key_hex"] == data["private_key_hex"]
        assert db["public_key_hex"] == data["public_key_hex"]

    @pytest.mark.dependency(depends=["TestClientEndpoints::test_assign_first"])
    def test_assign_second(self, client, test_env):
        resp = client.post("/api/core/clients/assign", json={"name": "bob"})
        assert resp.status_code == 201
        assert resp.json()["data"]["name"] == "bob"

        # DB state
        assert test_env.wallet.count_assigned() == 2

    @pytest.mark.dependency(depends=["TestClientEndpoints::test_assign_second"])
    def test_list_all(self, client, test_env):
        resp = client.get("/api/core/clients/list")
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is True
        data = body["data"]
        assert data["total"] == 2
        names = {c["name"] for c in data["clients"]}
        assert names == {"alice", "bob"}

        # Summary format — no secret keys
        for c in data["clients"]:
            assert "public_key_hex" in c
            assert "private_key_hex" not in c
            assert "preshared_key_hex" not in c

        # DB state
        assert data["total"] == test_env.wallet.count_assigned()

    @pytest.mark.dependency(depends=["TestClientEndpoints::test_assign_first"])
    def test_get_detail(self, client, test_env):
        resp = client.post("/api/core/clients/get", json={"name": "alice"})
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is True
        data = body["data"]
        assert data["name"] == "alice"
        assert "private_key_hex" in data
        assert "preshared_key_hex" in data

        # Exact match with DB
        db = test_env.wallet.get_client("alice")
        for key in ("id", "name", "ipv4_address", "ipv6_address",
                     "private_key_hex", "public_key_hex", "preshared_key_hex"):
            assert data[key] == db[key], f"Mismatch on {key}"

    def test_get_nonexistent(self, client):
        resp = client.post("/api/core/clients/get", json={"name": "ghost"})
        assert resp.status_code == 404
        assert resp.json()["ok"] is False

    @pytest.mark.dependency(depends=["TestClientEndpoints::test_assign_first"])
    def test_assign_duplicate(self, client):
        resp = client.post("/api/core/clients/assign", json={"name": "alice"})
        assert resp.status_code == 400
        body = resp.json()
        assert body["ok"] is False
        assert "error" in body

    def test_assign_invalid_name(self, client):
        resp = client.post("/api/core/clients/assign", json={"name": "bad name!"})
        assert resp.status_code == 422
        assert resp.json()["ok"] is False

    def test_assign_empty_name(self, client):
        resp = client.post("/api/core/clients/assign", json={"name": ""})
        assert resp.status_code == 422
        assert resp.json()["ok"] is False

    @pytest.mark.dependency(depends=["TestClientEndpoints::test_list_all"])
    def test_revoke(self, client, test_env):
        resp = client.post("/api/core/clients/revoke", json={"name": "alice"})
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is True
        assert body["data"]["status"] == "revoked"

        # DB state
        assert test_env.wallet.get_client("alice") is None

    @pytest.mark.dependency(depends=["TestClientEndpoints::test_revoke"])
    def test_revoke_already_revoked(self, client):
        resp = client.post("/api/core/clients/revoke", json={"name": "alice"})
        assert resp.status_code == 400
        body = resp.json()
        assert body["ok"] is False
        assert "error" in body

    @pytest.mark.dependency(depends=["TestClientEndpoints::test_revoke"])
    def test_list_after_revoke(self, client, test_env):
        resp = client.get("/api/core/clients/list")
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is True
        data = body["data"]
        assert data["total"] == 1
        assert data["clients"][0]["name"] == "bob"

        # DB state
        wallet = test_env.wallet
        assert wallet.count_assigned() == 1
        assert wallet.count_free() == wallet.count_users() - 1


class TestConfigExport:
    """Integration tests for POST /api/core/clients/config."""

    @pytest.fixture(autouse=True)
    def _setup(self, test_env):
        """Ensure a test client exists and provide endpoint-configured client."""
        self._test_env = test_env
        # Ensure 'charlie' exists for config tests
        if test_env.wallet.get_client("charlie") is None:
            result = test_env.wallet.assign_client("charlie")
            test_env.wg.add_peer(result, test_env.env.keepalive)

    def _make_client(self, endpoint_v4: str = "", endpoint_v6: str = ""):
        """Create a TestClient with custom endpoint config."""
        te = self._test_env
        env = DaemonEnv(
            db_dir=te.env.db_dir,
            state_dir=te.env.state_dir,
            listen_port=te.env.listen_port,
            mtu=te.env.mtu,
            keepalive=te.env.keepalive,
            endpoint_v4=endpoint_v4,
            endpoint_v6=endpoint_v6,
        )
        app = create_app(lifespan_func=None)
        app.state.wallet = te.wallet
        app.state.wg = te.wg
        app.state.env = env
        app.state.server_keys = te.server_keys
        return TestClient(app)

    def test_export_v4_config(self):
        te = self._test_env
        tc = self._make_client(endpoint_v4="vpn.example.com")
        resp = tc.post(
            "/api/core/clients/config",
            json={"name": "charlie", "version": "v4"},
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is True
        conf = base64.b64decode(body["data"]).decode()

        # Sections
        assert "[Interface]" in conf
        assert "[Peer]" in conf

        # Address — IPv4 only
        client_data = te.wallet.get_client("charlie")
        assert f"Address = {client_data['ipv4_address']}/32" in conf
        assert client_data["ipv6_address"] not in conf

        # Keys are base64
        assert hex_to_base64(client_data["private_key_hex"]) in conf
        assert hex_to_base64(te.server_keys.public_key_hex) in conf
        assert hex_to_base64(client_data["preshared_key_hex"]) in conf

        # Endpoint
        assert f"Endpoint = vpn.example.com:{te.env.listen_port}" in conf

        # AllowedIPs — v4 only
        assert "AllowedIPs = 0.0.0.0/0" in conf
        assert "::/0" not in conf

    def test_export_v6_config(self):
        te = self._test_env
        tc = self._make_client(endpoint_v6="vpn6.example.com")
        resp = tc.post(
            "/api/core/clients/config",
            json={"name": "charlie", "version": "v6"},
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is True
        conf = base64.b64decode(body["data"]).decode()

        client_data = te.wallet.get_client("charlie")
        assert f"Address = {client_data['ipv6_address']}/128" in conf
        assert client_data["ipv4_address"] not in conf
        assert "AllowedIPs = ::/0" in conf
        assert "0.0.0.0/0" not in conf
        assert f"Endpoint = vpn6.example.com:{te.env.listen_port}" in conf

    def test_export_hybrid_config(self):
        te = self._test_env
        tc = self._make_client(
            endpoint_v4="vpn.example.com",
            endpoint_v6="vpn6.example.com",
        )
        resp = tc.post(
            "/api/core/clients/config",
            json={"name": "charlie", "version": "hybrid"},
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is True
        conf = base64.b64decode(body["data"]).decode()

        client_data = te.wallet.get_client("charlie")
        assert (
            f"Address = {client_data['ipv4_address']}/32, "
            f"{client_data['ipv6_address']}/128"
        ) in conf
        assert "AllowedIPs = 0.0.0.0/0, ::/0" in conf
        # hybrid uses v4 endpoint
        assert f"Endpoint = vpn.example.com:{te.env.listen_port}" in conf

    def test_export_not_found(self):
        tc = self._make_client(endpoint_v4="vpn.example.com")
        resp = tc.post(
            "/api/core/clients/config",
            json={"name": "ghost", "version": "v4"},
        )
        assert resp.status_code == 404
        assert resp.json()["ok"] is False

    def test_export_missing_endpoint_v4(self):
        tc = self._make_client(endpoint_v4="")
        resp = tc.post(
            "/api/core/clients/config",
            json={"name": "charlie", "version": "v4"},
        )
        assert resp.status_code == 400
        assert resp.json()["ok"] is False

    def test_export_missing_endpoint_v6(self):
        tc = self._make_client(endpoint_v6="")
        resp = tc.post(
            "/api/core/clients/config",
            json={"name": "charlie", "version": "v6"},
        )
        assert resp.status_code == 400
        assert resp.json()["ok"] is False

    def test_export_hybrid_missing_v4(self):
        tc = self._make_client(endpoint_v4="", endpoint_v6="vpn6.example.com")
        resp = tc.post(
            "/api/core/clients/config",
            json={"name": "charlie", "version": "hybrid"},
        )
        assert resp.status_code == 400
        assert resp.json()["ok"] is False

    def test_export_hybrid_missing_v6(self):
        tc = self._make_client(endpoint_v4="vpn.example.com", endpoint_v6="")
        resp = tc.post(
            "/api/core/clients/config",
            json={"name": "charlie", "version": "hybrid"},
        )
        assert resp.status_code == 400
        assert resp.json()["ok"] is False
