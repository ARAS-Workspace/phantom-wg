"""Integration tests for /api/core/network endpoints.

API call → response check → DB state exact verification.
Tests are ordered via pytest-dependency within the class.
"""

from __future__ import annotations

import pytest


class TestNetworkEndpoints:

    def test_get_status(self, client, test_env):
        resp = client.get("/api/core/network")
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is True
        data = body["data"]

        # Structure
        assert "ipv4_subnet" in data
        assert "ipv6_subnet" in data
        assert "dns_v4" in data
        assert "dns_v6" in data
        assert "pool" in data

        # DB consistency
        wallet = test_env.wallet
        assert data["ipv4_subnet"] == wallet.get_config("ipv4_subnet")
        assert data["ipv6_subnet"] == wallet.get_config("ipv6_subnet")
        assert data["pool"]["total"] == wallet.count_users()
        assert data["pool"]["assigned"] == wallet.count_assigned()
        assert data["pool"]["free"] == wallet.count_free()

    def test_validate_pool(self, client):
        resp = client.get("/api/core/network/validate")
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is True
        data = body["data"]
        assert data["valid"] is True
        assert data["errors"] == []

    @pytest.mark.dependency()
    def test_change_cidr(self, client, test_env):
        resp = client.post("/api/core/network/cidr", json={"prefix": 22})
        assert resp.status_code == 200
        body = resp.json()
        assert body["ok"] is True
        data = body["data"]
        assert data["ipv4_subnet"] == "10.8.0.0/22"
        assert data["ipv6_subnet"] == "fd00:70:68::/118"
        assert data["pool"]["total"] == 1021

        # DB state
        wallet = test_env.wallet
        assert wallet.get_config("ipv4_subnet") == "10.8.0.0/22"
        assert wallet.get_config("ipv6_subnet") == "fd00:70:68::/118"
        assert wallet.count_users() == 1021

    @pytest.mark.dependency(depends=["TestNetworkEndpoints::test_change_cidr"])
    def test_change_cidr_resyncs_firewall(self, client, test_env):
        """The wallet is not the only thing a CIDR change has to reach.

        The masquerade source is baked into the core preset at resolve time,
        so before the endpoint resynced it, a client allocated outside the
        original subnet got no NAT — permanently, since bootstrap only ran
        on first boot.
        """
        from phantom_daemon.base.services.firewall.service import CORE_PRESET_NAME

        masq = [
            r for r in test_env.fw.list_firewall_rules(CORE_PRESET_NAME)
            if r.action == "masquerade"
        ]
        assert {r.source for r in masq} == {"10.8.0.0/22", "fd00:70:68::/118"}

    @pytest.mark.dependency(depends=["TestNetworkEndpoints::test_change_cidr"])
    def test_change_cidr_resyncs_peers(self, client, test_env):
        """Peer allowed_ips are pinned /32 to each client's address, and a
        CIDR change closes gaps left by revoked clients — so a client that
        sits after a gap moves, and its peer has to move with it.

        The gap matters: change_cidr re-slots in rowid order, which is IP
        order, so with a contiguous pool every client keeps its address and
        a stale peer is indistinguishable from a synced one.
        """
        names = ["gap-a", "gap-b", "gap-c"]
        try:
            for n in names:
                assert client.post(
                    "/api/core/clients/assign", json={"name": n}
                ).status_code == 201

            # Open a hole between gap-a and gap-c.
            client.post("/api/core/clients/revoke", json={"name": "gap-b"})
            before = test_env.wallet.get_client("gap-c")["ipv4_address"]

            client.post("/api/core/network/cidr", json={"prefix": 20})

            after = test_env.wallet.get_client("gap-c")["ipv4_address"]
            assert after != before, (
                "pool was contiguous — the test proves nothing about resync"
            )

            dump = test_env.wg._bridge.ipc_get()
            assert f"allowed_ip={after}/32" in dump, (
                f"peer still pinned to {before}, the pre-change address"
            )
            assert f"allowed_ip={before}/32" not in dump
        finally:
            # test_env is session-scoped and mutable, and the tests below
            # declare a dependency on the /22 this class established.
            for n in names:
                client.post("/api/core/clients/revoke", json={"name": n})
            client.post("/api/core/network/cidr", json={"prefix": 22})

    @pytest.mark.dependency(depends=["TestNetworkEndpoints::test_change_cidr"])
    def test_get_status_after_cidr(self, client, test_env):
        resp = client.get("/api/core/network")
        data = resp.json()["data"]
        wallet = test_env.wallet
        assert data["ipv4_subnet"] == "10.8.0.0/22"
        assert data["ipv6_subnet"] == "fd00:70:68::/118"
        assert data["pool"]["total"] == wallet.count_users()
        assert data["pool"]["assigned"] == wallet.count_assigned()

    @pytest.mark.dependency(depends=["TestNetworkEndpoints::test_change_cidr"])
    def test_validate_after_cidr(self, client):
        resp = client.get("/api/core/network/validate")
        data = resp.json()["data"]
        assert data["valid"] is True
        assert data["errors"] == []

    def test_invalid_prefix_low(self, client):
        resp = client.post("/api/core/network/cidr", json={"prefix": 8})
        assert resp.status_code == 422
        assert resp.json()["ok"] is False

    def test_invalid_prefix_high(self, client):
        resp = client.post("/api/core/network/cidr", json={"prefix": 31})
        assert resp.status_code == 422
        assert resp.json()["ok"] is False
