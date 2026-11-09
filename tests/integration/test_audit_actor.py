"""The actor of an audit row: "<id>-<name>" in user_id, the account acted on in detail.target."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import struct
import time

from auth_service.audit import account

PASSWORD = "Actor-Pass-2026!"
NEW_PASSWORD = "Actor-Next-2026!"


def latest(auth_env, action: str) -> tuple[str | None, dict]:
    """The actor and the detail of the newest row of an action."""
    row = next(r for r in auth_env.db.get_audit_logs() if r["action"] == action)
    return row["user_id"], json.loads(row["detail"])


def form(auth_env, username: str) -> str:
    return account(auth_env.db.get_user_by_username(username).id, username)


def totp_now(secret: str) -> str:
    mac = hmac.new(base64.b32decode(secret), struct.pack(">Q", int(time.time()) // 30), hashlib.sha1)
    digest = mac.digest()
    offset = digest[-1] & 0x0F
    return str((struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 10**6).zfill(6)


def mfa_token(client, username: str) -> str:
    resp = client.post("/auth/login", json={"username": username, "password": PASSWORD})
    return resp.json()["data"]["mfa_token"]


def test_the_form_is_the_id_a_dash_and_the_name():
    user_id = "0123456789abcdef0123456789abcdef"
    assert account(user_id, "ops-team-1") == f"{user_id}-ops-team-1"


# ── Login, MFA, logout ───────────────────────────────────────────


def test_a_login_writes_its_account(auth_env):
    auth_env.create_user("actor-login", PASSWORD)
    auth_env.login("actor-login", PASSWORD)
    assert latest(auth_env, "login_success") == (form(auth_env, "actor-login"), {})


def test_each_mfa_step_writes_its_account(auth_env):
    auth_env.create_user("actor-mfa", PASSWORD)
    setup = auth_env.enable_totp("actor-mfa", PASSWORD, auth_env.issue_token("actor-mfa"))
    me = form(auth_env, "actor-mfa")
    client = auth_env.make_client()

    token = mfa_token(client, "actor-mfa")
    assert latest(auth_env, "mfa_challenge") == (me, {})
    client.post("/auth/mfa/verify", json={"mfa_token": token, "code": "abcdef"})
    assert latest(auth_env, "mfa_failed") == (me, {})
    verified = client.post("/auth/mfa/verify", json={"mfa_token": token, "code": totp_now(setup["secret"])})
    assert verified.status_code == 200
    assert latest(auth_env, "mfa_success") == (me, {})

    token = mfa_token(client, "actor-mfa")
    client.post("/auth/totp/backup", json={"mfa_token": token, "code": "zzzzzzzz"})
    assert latest(auth_env, "backup_code_failed") == (me, {})
    used = client.post("/auth/totp/backup", json={"mfa_token": token, "code": setup["backup_codes"][0]})
    assert used.status_code == 200
    assert latest(auth_env, "backup_code_used") == (me, {"remaining": len(setup["backup_codes"]) - 1})
    assert latest(auth_env, "login_success") == (me, {})


def test_logout_writes_the_actor(auth_env):
    auth_env.create_user("actor-out", PASSWORD)
    token = auth_env.issue_token("actor-out")
    auth_env.make_client().post("/auth/logout", headers=auth_env.bearer(token))
    assert latest(auth_env, "logout") == (form(auth_env, "actor-out"), {})


# ── The account's own changes: actor, no target ──────────────────


def test_an_own_password_change_writes_the_actor(auth_env):
    auth_env.create_user("actor-pw", PASSWORD)
    headers = auth_env.bearer(auth_env.issue_token("actor-pw"))
    client = auth_env.make_client()
    verify = client.post("/auth/password/verify", json={"password": PASSWORD}, headers=headers)
    change = {"change_token": verify.json()["data"]["change_token"], "password": NEW_PASSWORD}
    assert client.post("/auth/password/change", json=change, headers=headers).status_code == 200
    me = form(auth_env, "actor-pw")
    assert latest(auth_env, "password_change_started") == (me, {})
    assert latest(auth_env, "password_changed") == (me, {})


def test_totp_setup_writes_the_actor(auth_env):
    auth_env.create_user("actor-totp", PASSWORD)
    auth_env.enable_totp("actor-totp", PASSWORD, auth_env.issue_token("actor-totp"))
    me = form(auth_env, "actor-totp")
    assert latest(auth_env, "totp_setup_started") == (me, {})
    assert latest(auth_env, "totp_enabled") == (me, {})


# ── Changes to another account: the superadmin and the target ────


def test_user_management_writes_the_superadmin_and_the_target(auth_env):
    auth_env.create_user("actor-root", PASSWORD, role="superadmin")
    headers = auth_env.bearer(auth_env.issue_token("actor-root"))
    client = auth_env.make_client()
    root = form(auth_env, "actor-root")

    created = client.post("/auth/users", json={"username": "ops-target", "password": PASSWORD},
                          headers=headers)
    assert created.status_code == 200
    target = form(auth_env, "ops-target")
    assert latest(auth_env, "user_created") == (root, {"target": target})

    reset = client.post("/auth/users/ops-target/password", json={"password": NEW_PASSWORD},
                        headers=headers)
    assert reset.status_code == 200
    assert latest(auth_env, "password_changed") == (root, {"target": target})

    auth_env.enable_totp("ops-target", NEW_PASSWORD, auth_env.issue_token("ops-target"))
    disabled = client.post("/auth/totp/disable", json={"password": PASSWORD, "username": "ops-target"},
                           headers=headers)
    assert disabled.status_code == 200
    assert latest(auth_env, "totp_disabled") == (root, {"target": target})

    assert client.delete("/auth/users/ops-target", headers=headers).status_code == 200
    assert latest(auth_env, "user_deleted") == (root, {"target": target})


def test_the_name_of_a_deleted_actor_stays_readable(auth_env):
    auth_env.create_user("actor-root2", PASSWORD, role="superadmin")
    headers = auth_env.bearer(auth_env.issue_token("actor-root2"))
    gone = auth_env.create_user("gone-ops", PASSWORD)
    client = auth_env.make_client()
    client.post("/auth/logout", headers=auth_env.bearer(auth_env.issue_token("gone-ops")))
    assert client.delete("/auth/users/gone-ops", headers=headers).status_code == 200

    resp = client.get("/auth/audit?username=gone-ops", headers=headers)
    items = resp.json()["data"]["items"]
    assert [(i["action"], i["user_id"], i["username"]) for i in items] == [
        ("logout", gone.id, "gone-ops"),
    ]


# ── Proxy ────────────────────────────────────────────────────────


def test_a_proxy_request_writes_the_actor(auth_env):
    auth_env.create_user("actor-proxy", PASSWORD)
    headers = auth_env.bearer(auth_env.issue_token("actor-proxy"))
    resp = auth_env.make_client().get("/api/core/nonexistent", headers=headers)
    assert resp.status_code == 404
    actor, detail = latest(auth_env, "proxy_request")
    assert actor == form(auth_env, "actor-proxy")
    assert detail["status"] == 404
