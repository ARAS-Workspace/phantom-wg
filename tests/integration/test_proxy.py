from __future__ import annotations

import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from auth_service.middleware.rate_limit import RateLimiter


@pytest.fixture()
def mock_daemon():
    """Mock httpx async client returning daemon-like responses."""
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {"ok": True, "data": {"clients": []}}
    mock_response.headers = {"content-type": "application/json"}

    mock_client = AsyncMock()
    mock_client.request = AsyncMock(return_value=mock_response)
    return mock_client


@pytest.fixture()
def mock_daemon_404():
    """Mock httpx async client returning 404."""
    mock_response = MagicMock()
    mock_response.status_code = 404
    mock_response.json.return_value = {"ok": False, "error": "Not found"}
    mock_response.headers = {"content-type": "application/json"}

    mock_client = AsyncMock()
    mock_client.request = AsyncMock(return_value=mock_response)
    return mock_client


@pytest.fixture()
def mock_daemon_error():
    """Mock httpx async client that raises ConnectionError."""
    mock_client = AsyncMock()
    mock_client.request = AsyncMock(side_effect=ConnectionError("daemon down"))
    return mock_client


def _proxy_client(auth_env, mock):
    return auth_env.make_client(
        proxy_client=mock,
        rate_limiter=RateLimiter(window=60, max_attempts=100),
    )


# ── Existing proxy tests ──────────────────────────────────────────


def test_proxy_get(auth_env, mock_daemon):
    auth_env.create_user("proxyuser", "proxypass1")
    token = auth_env.issue_token("proxyuser")
    client = _proxy_client(auth_env, mock_daemon)
    resp = client.get("/api/core/clients/list", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    assert resp.json()["ok"] is True


def test_proxy_post(auth_env, mock_daemon):
    auth_env.create_user("proxypost", "proxypass1")
    token = auth_env.issue_token("proxypost")
    client = _proxy_client(auth_env, mock_daemon)
    resp = client.post(
        "/api/core/clients/assign",
        json={"name": "test"},
        headers=auth_env.bearer(token),
    )
    assert resp.status_code == 200


def test_proxy_no_auth(auth_env, mock_daemon):
    client = auth_env.make_client(proxy_client=mock_daemon)
    resp = client.get("/api/core/clients/list")
    assert resp.status_code == 401


def test_proxy_revoked_token(auth_env, mock_daemon):
    auth_env.create_user("revoked", "revokepass")
    token = auth_env.issue_token("revoked")
    from auth_service.crypto.jwt import decode_token
    payload = decode_token(auth_env.verify_key, token)
    auth_env.db.revoke_session(payload.jti)

    client = auth_env.make_client(proxy_client=mock_daemon)
    resp = client.get("/api/core/clients/list", headers=auth_env.bearer(token))
    assert resp.status_code == 401


# ── Proxy audit tests ─────────────────────────────────────────────


def test_proxy_audit_get(auth_env, mock_daemon):
    """Successful GET creates proxy_request audit entry with method/path/status."""
    auth_env.create_user("auditget", "auditpass1")
    token = auth_env.issue_token("auditget")
    client = _proxy_client(auth_env, mock_daemon)
    client.get("/api/core/clients/list?page=1&limit=25", headers=auth_env.bearer(token))

    logs = auth_env.db.get_audit_logs()
    proxy_logs = [l for l in logs if l["action"] == "proxy_request"]
    assert len(proxy_logs) == 1

    detail = json.loads(proxy_logs[0]["detail"])
    assert detail["method"] == "GET"
    assert detail["path"] == "/api/core/clients/list"
    assert detail["query"] == "page=1&limit=25"
    assert detail["status"] == 200


def test_proxy_audit_post(auth_env, mock_daemon):
    """POST request is audited with correct method."""
    auth_env.create_user("auditpost", "auditpass1")
    token = auth_env.issue_token("auditpost")
    client = _proxy_client(auth_env, mock_daemon)
    client.post("/api/core/clients/assign", json={"name": "x"}, headers=auth_env.bearer(token))

    logs = auth_env.db.get_audit_logs()
    proxy_logs = [l for l in logs if l["action"] == "proxy_request"]
    assert len(proxy_logs) == 1

    detail = json.loads(proxy_logs[0]["detail"])
    assert detail["method"] == "POST"
    assert detail["path"] == "/api/core/clients/assign"
    assert detail["status"] == 200
    assert "query" not in detail  # POST without query string


def test_proxy_audit_user_id(auth_env, mock_daemon):
    """Audit entry links to correct user_id."""
    user = auth_env.create_user("audituid", "auditpass1")
    token = auth_env.issue_token("audituid")
    client = _proxy_client(auth_env, mock_daemon)
    client.get("/api/core/hello", headers=auth_env.bearer(token))

    logs = auth_env.db.get_audit_logs()
    proxy_logs = [l for l in logs if l["action"] == "proxy_request"]
    assert proxy_logs[0]["user_id"] == user.id


def test_proxy_audit_daemon_error(auth_env, mock_daemon_error):
    """502 daemon error is audited."""
    auth_env.create_user("auditerr", "auditpass1")
    token = auth_env.issue_token("auditerr")
    client = _proxy_client(auth_env, mock_daemon_error)
    resp = client.get("/api/core/hello", headers=auth_env.bearer(token))
    assert resp.status_code == 502

    logs = auth_env.db.get_audit_logs()
    proxy_logs = [l for l in logs if l["action"] == "proxy_request"]
    assert len(proxy_logs) == 1

    detail = json.loads(proxy_logs[0]["detail"])
    assert detail["status"] == 502


def test_proxy_audit_upstream_error(auth_env, mock_daemon_404):
    """Non-200 daemon response status is recorded in audit detail."""
    auth_env.create_user("audit404", "auditpass1")
    token = auth_env.issue_token("audit404")
    client = _proxy_client(auth_env, mock_daemon_404)
    resp = client.get("/api/core/hello", headers=auth_env.bearer(token))
    assert resp.status_code == 404

    logs = auth_env.db.get_audit_logs()
    proxy_logs = [l for l in logs if l["action"] == "proxy_request"]
    detail = json.loads(proxy_logs[0]["detail"])
    assert detail["status"] == 404


def test_proxy_audit_no_entry_on_401(auth_env, mock_daemon):
    """Unauthenticated request does NOT create audit entry (auth fails before proxy)."""
    client = auth_env.make_client(proxy_client=mock_daemon)
    client.get("/api/core/hello")

    logs = auth_env.db.get_audit_logs()
    proxy_logs = [l for l in logs if l["action"] == "proxy_request"]
    assert len(proxy_logs) == 0


def test_proxy_audit_filterable(auth_env, mock_daemon):
    """proxy_request entries are filterable via GET /auth/audit?action=proxy_request."""
    auth_env.create_user("filtadmin", "FiltAdmPw1!", role="superadmin")
    token = auth_env.login("filtadmin", "FiltAdmPw1!")
    client = _proxy_client(auth_env, mock_daemon)

    # Make 3 proxy requests
    for _ in range(3):
        client.get("/api/core/hello", headers=auth_env.bearer(token))

    # Query audit endpoint
    resp = client.get("/auth/audit?action=proxy_request", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    items = resp.json()["data"]["items"]
    assert len(items) == 3
    assert all(i["action"] == "proxy_request" for i in items)
