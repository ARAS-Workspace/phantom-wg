"""The route table: exact matches, the role per route, the body limit per route."""

from __future__ import annotations

import asyncio
import json
from urllib.parse import unquote

import httpx
import pytest
from fastapi import FastAPI, Request

from auth_service.config import load_auth_config
from auth_service.middleware.rate_limit import RateLimiter
from auth_service.routes.proxy import GRANTS, ROUTES, Access, Role

BACKUP_ROUTES = ["/api/core/backup/export", "/api/core/backup/import"]

# Spellings of /api/core/backup/export. The first three decode to the route
# itself, so the role decides; the others are not in the route table.
DECODED_SPELLINGS = ["/api/core/%62ackup/export", "/api/core%2Fbackup%2Fexport"]
OTHER_SPELLINGS = [
    "/api/core/x/../backup/export",
    "/api/core/./backup/export",
    "/api/x/../core/backup/export",
    "/api/core/%2562ackup/export",
    "/api/core//backup/export",
    "/api/core/backup/export/",
]


class Daemon:
    """Real Starlette routing and a real httpx transport, as over the UDS."""

    def __init__(self) -> None:
        self.hits: list[str] = []
        self.queries: list[str] = []
        app = FastAPI()

        async def record(request: Request) -> dict:
            self.hits.append(str(request.url.path))
            self.queries.append(request.url.query)
            return {"ok": True, "size": len(await request.body())}

        app.add_api_route("/api/{rest:path}", record, methods=["GET", "POST"])
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=app))


@pytest.fixture()
def daemon():
    return Daemon()


@pytest.fixture()
def client(auth_env, daemon):
    return auth_env.make_client(
        proxy_client=daemon.client,
        rate_limiter=RateLimiter(window=60, max_attempts=100),
    )


@pytest.fixture()
def admin(auth_env):
    auth_env.create_user("backup-admin", "backuppass1", role="admin")
    return auth_env.issue_token("backup-admin")


@pytest.fixture()
def superadmin(auth_env):
    auth_env.create_user("backup-root", "backuppass1", role="superadmin")
    return auth_env.issue_token("backup-root")


def send(client, raw_path: str, token: str, method: str = "POST",
         body: bytes = b"", query: bytes = b"") -> int:
    """One request with the path as nginx forwards it, not normalized by a client."""
    sent: list[int] = []

    async def receive() -> dict:
        return {"type": "http.request", "body": body, "more_body": False}

    async def respond(message: dict) -> None:
        if message["type"] == "http.response.start":
            sent.append(message["status"])

    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": method,
        "scheme": "https",
        "path": unquote(raw_path),
        "raw_path": raw_path.encode(),
        "root_path": "",
        "query_string": query,
        "headers": [
            (b"host", b"testserver"),
            (b"authorization", f"Bearer {token}".encode()),
            (b"content-length", str(len(body)).encode()),
        ],
        "client": ("172.28.0.4", 40000),
        "server": ("testserver", 443),
    }
    asyncio.run(client.app(scope, receive, respond))
    return sent[0]


# ── Role ─────────────────────────────────────────────────────────


@pytest.mark.parametrize("route", BACKUP_ROUTES)
def test_admin_is_refused_on_backup(client, daemon, admin, route):
    assert send(client, route, admin) == 403
    assert daemon.hits == []


@pytest.mark.parametrize("route", BACKUP_ROUTES)
def test_superadmin_reaches_backup(client, daemon, superadmin, route):
    assert send(client, route, superadmin) == 200
    assert daemon.hits == [route]


@pytest.mark.parametrize("route", DECODED_SPELLINGS)
def test_decoded_spelling_is_the_route_itself(client, daemon, admin, route):
    assert send(client, route, admin) == 403
    assert daemon.hits == []


@pytest.mark.parametrize("route", OTHER_SPELLINGS)
def test_other_spelling_is_not_a_route(client, daemon, superadmin, route):
    assert send(client, route, superadmin) == 404
    assert daemon.hits == []


@pytest.mark.parametrize(("method", "route"), sorted(ROUTES))
def test_every_route_answers_by_its_access(client, daemon, admin, superadmin, method, route):
    backup = route in BACKUP_ROUTES
    assert send(client, route, admin, method=method) == (403 if backup else 200)
    assert send(client, route, superadmin, method=method) == 200
    assert daemon.hits == ([route] if backup else [route, route])


@pytest.mark.parametrize("route", ["/api/core/nonexistent", "/api/core/backups", "/api/core/backup"])
def test_route_outside_the_table_does_not_reach_the_daemon(client, daemon, superadmin, route):
    assert send(client, route, superadmin) == 404
    assert daemon.hits == []


@pytest.mark.parametrize(("method", "route"), [
    ("GET", "/api/core/backup/export"),
    ("POST", "/api/core/clients/list"),
    ("DELETE", "/api/core/clients/assign"),
])
def test_method_is_part_of_the_match(client, daemon, superadmin, method, route):
    assert send(client, route, superadmin, method=method) == 404
    assert daemon.hits == []


def test_role_outside_the_access_is_refused(auth_env, client, daemon):
    auth_env.create_user("backup-other", "backuppass1", role="auditor")
    token = auth_env.issue_token("backup-other")
    assert send(client, "/api/core/clients/list", token, method="GET") == 403
    assert daemon.hits == []


def test_query_reaches_the_daemon(client, daemon, admin):
    send(client, "/api/core/clients/list", admin, method="GET", query=b"page=2&limit=5")
    assert daemon.queries == ["page=2&limit=5"]


def test_unknown_route_is_audited(auth_env, client, admin):
    send(client, "/api/core/nonexistent", admin)
    logs = [row for row in auth_env.db.get_audit_logs() if row["action"] == "proxy_request"]
    assert json.loads(logs[0]["detail"])["status"] == 404


def test_grants_decide_the_roles_of_a_whole_access(monkeypatch, client, daemon, admin):
    monkeypatch.setitem(GRANTS, Access.OPERATE, frozenset({Role.SUPERADMIN}))
    assert send(client, "/api/core/clients/assign", admin) == 403
    assert send(client, "/api/core/clients/list", admin, method="GET") == 200
    assert daemon.hits == ["/api/core/clients/list"]


@pytest.mark.parametrize("route", [
    "/api/core/clients/assign",
    "/api/core/clients/config",
    "/api/core/clients/get",
])
def test_routes_carrying_a_client_key_are_not_view(route):
    assert ROUTES[("POST", route)].access is Access.OPERATE


def test_custody_is_the_backup_routes():
    custody = sorted(path for (_, path), r in ROUTES.items() if r.access is Access.CUSTODY)
    assert custody == BACKUP_ROUTES


def test_large_body_is_the_backup_routes():
    large = sorted(path for (_, path), r in ROUTES.items() if r.large_body)
    assert large == BACKUP_ROUTES


def test_refusal_is_audited(auth_env, client, admin):
    send(client, "/api/core/backup/export", admin)
    logs = [row for row in auth_env.db.get_audit_logs() if row["action"] == "proxy_request"]
    assert len(logs) == 1
    detail = json.loads(logs[0]["detail"])
    assert detail["path"] == "/api/core/backup/export"
    assert detail["status"] == 403


# ── Body limits ──────────────────────────────────────────────────


def test_body_at_the_limit_passes(auth_env, client, daemon, admin):
    body = b"x" * auth_env.config.proxy_max_body
    assert send(client, "/api/core/clients/assign", admin, body=body) == 200
    assert daemon.hits == ["/api/core/clients/assign"]


def test_body_over_the_limit_is_refused(auth_env, client, daemon, admin):
    body = b"x" * (auth_env.config.proxy_max_body + 1)
    assert send(client, "/api/core/clients/assign", admin, body=body) == 413
    assert daemon.hits == []


def test_superadmin_has_the_large_limit_on_backup_alone(auth_env, client, daemon, superadmin):
    body = b"x" * (auth_env.config.proxy_max_body + 1)
    assert send(client, "/api/core/clients/assign", superadmin, body=body) == 413
    assert daemon.hits == []


def test_backup_takes_a_body_up_to_its_limit(auth_env, client, daemon, superadmin):
    body = b"x" * auth_env.config.proxy_backup_max_body
    assert send(client, "/api/core/backup/import", superadmin, body=body) == 200
    assert daemon.hits == ["/api/core/backup/import"]


def test_backup_limit_holds(auth_env, client, daemon, superadmin):
    body = b"x" * (auth_env.config.proxy_backup_max_body + 1)
    assert send(client, "/api/core/backup/import", superadmin, body=body) == 413
    assert daemon.hits == []


def test_body_limit_defaults(monkeypatch):
    monkeypatch.delenv("AUTH_PROXY_MAX_BODY", raising=False)
    monkeypatch.delenv("AUTH_PROXY_BACKUP_MAX_BODY", raising=False)
    config = load_auth_config()
    assert config.proxy_max_body == 65536
    assert config.proxy_backup_max_body == 67108864


def test_body_limits_come_from_env(monkeypatch):
    monkeypatch.setenv("AUTH_PROXY_MAX_BODY", "1024")
    monkeypatch.setenv("AUTH_PROXY_BACKUP_MAX_BODY", "2048")
    config = load_auth_config()
    assert config.proxy_max_body == 1024
    assert config.proxy_backup_max_body == 2048
