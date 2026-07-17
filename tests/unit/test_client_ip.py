from __future__ import annotations

from types import SimpleNamespace

import pytest
from starlette.requests import Request

from auth_service.audit import get_client_ip
from auth_service.config import _DEFAULT_TRUSTED_PROXIES, _parse_trusted_proxies


def _request(peer: str | None, xff: str | None = None,
             trusted: str = _DEFAULT_TRUSTED_PROXIES) -> Request:
    """Build a minimal Starlette Request with a given peer and XFF header."""
    headers = []
    if xff is not None:
        headers.append((b"x-forwarded-for", xff.encode()))
    app = SimpleNamespace(state=SimpleNamespace(
        config=SimpleNamespace(trusted_proxies=_parse_trusted_proxies(trusted)),
    ))
    return Request({
        "type": "http",
        "method": "GET",
        "path": "/",
        "headers": headers,
        "client": (peer, 12345) if peer else None,
        "app": app,
    })


# ── Untrusted peer: header is ignored entirely ───────────────────


def test_direct_untrusted_peer_ignores_xff():
    req = _request("203.0.113.7", xff="1.2.3.4")
    assert get_client_ip(req) == "203.0.113.7"


def test_testclient_hostname_is_untrusted():
    # starlette TestClient's default peer is not an IP → never trusted
    req = _request("testclient", xff="1.2.3.4")
    assert get_client_ip(req) == "testclient"


def test_no_client_returns_empty():
    assert get_client_ip(_request(None)) == ""


# ── Trusted peer: right-to-left walk ─────────────────────────────


def test_trusted_peer_single_entry():
    req = _request("172.28.0.2", xff="203.0.113.7")
    assert get_client_ip(req) == "203.0.113.7"


def test_spoofed_prefix_never_wins():
    # nginx appends to the incoming header, so a spoofed value survives
    # as the leftmost entry — the rightmost untrusted one is the client.
    req = _request("172.28.0.2", xff="6.6.6.6, 203.0.113.7")
    assert get_client_ip(req) == "203.0.113.7"


def test_trusted_hops_are_skipped():
    req = _request("172.28.0.2", xff="203.0.113.7, 172.28.0.5")
    assert get_client_ip(req) == "203.0.113.7"


def test_all_trusted_chain_returns_leftmost():
    req = _request("172.28.0.2", xff="172.28.0.3, 172.28.0.4")
    assert get_client_ip(req) == "172.28.0.3"


def test_malformed_entry_stops_walk():
    # garbage left of a trusted hop: keep the last verified address
    req = _request("172.28.0.2", xff="garbage, 172.28.0.5")
    assert get_client_ip(req) == "172.28.0.5"


def test_no_xff_returns_trusted_peer():
    req = _request("172.28.0.2")
    assert get_client_ip(req) == "172.28.0.2"


def test_custom_trust_list():
    # peer outside the configured trust list → header ignored
    req = _request("192.168.1.9", xff="203.0.113.7", trusted="192.168.0.0/16")
    assert get_client_ip(req) == "203.0.113.7"
    req = _request("172.28.0.2", xff="203.0.113.7", trusted="192.168.0.0/16")
    assert get_client_ip(req) == "172.28.0.2"


# ── Config parsing ───────────────────────────────────────────────


def test_parse_trusted_proxies_custom():
    nets = _parse_trusted_proxies("198.51.100.0/24, 2001:db8::/32")
    assert len(nets) == 2
    assert str(nets[0]) == "198.51.100.0/24"


def test_parse_trusted_proxies_empty():
    assert _parse_trusted_proxies("") == ()


def test_parse_trusted_proxies_invalid_raises():
    with pytest.raises(ValueError):
        _parse_trusted_proxies("not-a-cidr")


def test_default_is_exactly_the_compose_network():
    # networks.phantom-net.ipam in the daemon compose — nothing wider.
    nets = _parse_trusted_proxies(_DEFAULT_TRUSTED_PROXIES)
    import ipaddress
    for ip in ("172.28.0.2", "fd00:d0ce::5"):
        assert any(ipaddress.ip_address(ip) in n for n in nets), ip
    for ip in ("127.0.0.1", "10.8.0.1", "192.168.1.1", "172.29.0.2", "fd00::1"):
        assert not any(ipaddress.ip_address(ip) in n for n in nets), ip


def test_env_override(monkeypatch):
    monkeypatch.setenv("AUTH_TRUSTED_PROXIES", "198.51.100.0/24")
    from auth_service.config import load_auth_config
    config = load_auth_config()
    assert len(config.trusted_proxies) == 1
    assert str(config.trusted_proxies[0]) == "198.51.100.0/24"


# ── End-to-end: spoofed header never reaches the audit log ───────


def test_spoofed_xff_never_reaches_audit(auth_env):
    client = auth_env.make_client()
    client.post(
        "/auth/login",
        json={"username": "ghost", "password": "nope"},
        headers={"x-forwarded-for": "6.6.6.6"},
    )
    result = auth_env.db.get_audit_logs_paginated(page=1, limit=10, ip="6.6.6.6")
    assert result["total"] == 0
