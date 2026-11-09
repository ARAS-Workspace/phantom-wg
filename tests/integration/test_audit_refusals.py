"""What an authenticated account is refused on /auth, and its reading of the audit log."""

from __future__ import annotations

import json

import pytest

from auth_service.audit import account

PASSWORD = "Refusal-Pass-2026!"
WRONG = "Wrong-Pass-2026!"


def rows(auth_env, *actions: str) -> list[tuple[str, str | None, dict]]:
    """Every row of the actions, oldest first: action, actor, detail."""
    found = [r for r in auth_env.db.get_audit_logs() if r["action"] in actions]
    return [(r["action"], r["user_id"], json.loads(r["detail"])) for r in reversed(found)]


def form(auth_env, username: str) -> str:
    return account(auth_env.db.get_user_by_username(username).id, username)


@pytest.fixture()
def admin(auth_env):
    auth_env.create_user("refused-admin", PASSWORD)
    return auth_env.bearer(auth_env.issue_token("refused-admin"))


@pytest.fixture()
def root(auth_env):
    auth_env.create_user("refused-root", PASSWORD, role="superadmin")
    return auth_env.bearer(auth_env.issue_token("refused-root"))


# ── A wrong password or code from the token holder ───────────────


def test_a_wrong_password_on_each_step_is_reauth_failed(auth_env, admin):
    client = auth_env.make_client()
    steps = [
        ("/auth/password/verify", {"password": WRONG}, "INVALID_PASSWORD"),
        ("/auth/totp/setup", {"password": WRONG}, "INVALID_PASSWORD"),
        ("/auth/totp/disable", {"password": WRONG}, "INVALID_PASSWORD"),
    ]
    for path, body, code in steps:
        assert client.post(path, json=body, headers=admin).json()["error_code"] == code
    me = form(auth_env, "refused-admin")
    assert rows(auth_env, "reauth_failed", "request_refused") == [
        ("reauth_failed", me, {"method": "POST", "path": path, "status": 401, "code": code})
        for path, _, code in steps
    ]
    assert WRONG not in json.dumps([r["detail"] for r in auth_env.db.get_audit_logs()])


def test_a_wrong_code_at_totp_confirm_is_reauth_failed(auth_env, admin):
    client = auth_env.make_client()
    setup = client.post("/auth/totp/setup", json={"password": PASSWORD}, headers=admin).json()["data"]
    resp = client.post("/auth/totp/confirm", json={"setup_token": setup["setup_token"], "code": "abcdef"},
                       headers=admin)
    assert resp.json()["error_code"] == "INVALID_TOTP_CODE"
    assert rows(auth_env, "reauth_failed") == [
        ("reauth_failed", form(auth_env, "refused-admin"),
         {"method": "POST", "path": "/auth/totp/confirm", "status": 401, "code": "INVALID_TOTP_CODE"}),
    ]


# ── Any other refusal on a change route ──────────────────────────


@pytest.mark.parametrize(("who", "method", "path", "body", "status", "code"), [
    ("admin", "POST", "/auth/users", {"username": "x-new", "password": PASSWORD}, 403,
     "SUPERADMIN_REQUIRED"),
    ("admin", "POST", "/auth/users/refused-root/password", {"password": PASSWORD}, 403,
     "CANNOT_CHANGE_OTHERS_PASSWORD"),
    ("admin", "POST", "/auth/totp/disable", {"password": PASSWORD, "username": "refused-root"}, 403,
     "CANNOT_DISABLE_OTHERS_TOTP"),
    ("root", "DELETE", "/auth/users/refused-root", None, 400, "CANNOT_DELETE_SELF"),
    ("root", "DELETE", "/auth/users/nobody-here", None, 404, "USER_NOT_FOUND"),
    ("root", "POST", "/auth/users", {"username": "refused-admin", "password": PASSWORD}, 409,
     "USER_ALREADY_EXISTS"),
    ("root", "POST", "/auth/password/change", {"change_token": "x", "password": PASSWORD}, 401,
     "TOKEN_INVALID"),
    ("root", "POST", "/auth/users/refused-admin/password", {"password": "weak"}, 422,
     "VALIDATION_ERROR"),
])
def test_a_refused_change_is_request_refused(auth_env, admin, root, who, method, path, body,
                                             status, code):
    headers = admin if who == "admin" else root
    resp = auth_env.make_client().request(method, path, json=body, headers=headers)
    assert (resp.status_code, resp.json()["error_code"]) == (status, code)
    actor = form(auth_env, f"refused-{who}")
    assert rows(auth_env, "reauth_failed", "request_refused") == [
        ("request_refused", actor, {"method": method, "path": path, "status": status, "code": code}),
    ]


# ── Read routes: a 403 only ──────────────────────────────────────


@pytest.mark.parametrize("path", ["/auth/users", "/auth/audit"])
def test_a_refused_read_writes_its_403(auth_env, admin, path):
    resp = auth_env.make_client().get(path, headers=admin)
    assert resp.status_code == 403
    assert rows(auth_env, "request_refused") == [
        ("request_refused", form(auth_env, "refused-admin"),
         {"method": "GET", "path": path, "status": 403, "code": "SUPERADMIN_REQUIRED"}),
    ]


def test_a_malformed_read_writes_no_refusal(auth_env, root):
    resp = auth_env.make_client().get("/auth/audit?limit=1000", headers=root)
    assert resp.status_code == 422
    assert rows(auth_env, "request_refused", "audit_viewed") == []


# ── What writes no refusal row ───────────────────────────────────


def test_a_request_with_no_token_writes_nothing(auth_env):
    resp = auth_env.make_client().post("/auth/users", json={"username": "x-new", "password": PASSWORD})
    assert resp.status_code == 401
    assert rows(auth_env, "reauth_failed", "request_refused") == []


def test_a_proxy_refusal_writes_one_row(auth_env, admin):
    resp = auth_env.make_client().post("/api/core/backup/export", headers=admin)
    assert resp.status_code == 403
    assert [r["action"] for r in auth_env.db.get_audit_logs()] == ["proxy_request"]


# ── Reading the audit log ────────────────────────────────────────


def test_reading_the_audit_log_is_written_with_its_query(auth_env, root):
    client = auth_env.make_client()
    first = client.get("/auth/audit?action=user_created&page=1&limit=10", headers=root)
    assert first.status_code == 200
    assert first.json()["data"]["items"] == []
    assert rows(auth_env, "audit_viewed") == [
        ("audit_viewed", form(auth_env, "refused-root"),
         {"page": 1, "limit": 10, "order": "desc", "action": "user_created"}),
    ]
    second = client.get("/auth/audit", headers=root)
    assert [i["action"] for i in second.json()["data"]["items"]] == ["audit_viewed"]


def test_the_pages_of_one_query_keep_their_rows(auth_env, root):
    # Each page writes audit_viewed on top of the log; as_of keeps it off the next page.
    for n in range(4):
        auth_env.db.add_audit_log(f"row{n}", {}, ip_address="1.0.0.1")
    client = auth_env.make_client()
    first = client.get("/auth/audit?page=1&limit=2", headers=root).json()["data"]
    second = client.get(f"/auth/audit?page=2&limit=2&as_of={first['as_of']}", headers=root)
    page = second.json()["data"]
    assert [i["action"] for i in first["items"]] == ["row3", "row2"]
    assert [i["action"] for i in page["items"]] == ["row1", "row0"]
    assert (page["total"], page["as_of"]) == (4, first["as_of"])
    assert rows(auth_env, "audit_viewed")[-1][2]["as_of"] == first["as_of"]
