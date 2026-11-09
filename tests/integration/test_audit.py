from __future__ import annotations

import json
import logging

import pytest

from auth_service.audit import account
from auth_service.middleware.rate_limit import RateLimiter

REFUSED = {"login_failed", "login_rate_limited", "mfa_rate_limited", "backup_code_rate_limited"}
WRONG = "Wrong-Pass-2026!"


def actions(auth_env) -> list[str]:
    return [row["action"] for row in auth_env.db.get_audit_logs()]


def service_lines(caplog) -> list[str]:
    return [record.getMessage() for record in caplog.records if record.name == "phantom-auth"]


# ── A refused login: one service log line, no audit row ──────────


def test_a_failed_login_goes_to_the_service_log(auth_env, caplog):
    auth_env.create_user("audituser", "auditpw12")
    client = auth_env.make_client()
    with caplog.at_level(logging.WARNING, logger="phantom-auth"):
        resp = client.post("/auth/login", json={"username": "audituser", "password": WRONG})
    assert resp.status_code == 401
    assert service_lines(caplog) == ['login_failed ip=testclient username="audituser"']
    assert REFUSED.isdisjoint(actions(auth_env))
    assert WRONG not in caplog.text


@pytest.mark.parametrize(("path", "body", "line"), [
    ("/auth/login", {"username": "x", "password": WRONG},
     'login_rate_limited ip=testclient username="x"'),
    ("/auth/mfa/verify", {"mfa_token": "t", "code": "123456"},
     "mfa_rate_limited ip=testclient"),
    ("/auth/totp/backup", {"mfa_token": "t", "code": "12345678"},
     "backup_code_rate_limited ip=testclient"),
])
def test_a_rate_limited_attempt_goes_to_the_service_log(auth_env, caplog, path, body, line):
    client = auth_env.make_client(rate_limiter=RateLimiter(window=60, max_attempts=0))
    with caplog.at_level(logging.WARNING, logger="phantom-auth"):
        resp = client.post(path, json=body)
    assert resp.status_code == 429
    assert service_lines(caplog) == [line]
    assert REFUSED.isdisjoint(actions(auth_env))
    assert WRONG not in caplog.text


def test_the_sent_name_cannot_start_a_new_log_line(auth_env, caplog):
    name = 'adm\nin" ip=203.0.113.9'
    client = auth_env.make_client()
    with caplog.at_level(logging.WARNING, logger="phantom-auth"):
        client.post("/auth/login", json={"username": name, "password": WRONG})
    lines = service_lines(caplog)
    assert lines == [f"login_failed ip=testclient username={json.dumps(name)}"]
    assert "\n" not in lines[0]


def test_a_failed_second_step_stays_in_the_audit_log(auth_env, caplog):
    # The password was right: the operator sees in the audit log that
    # someone holds it and is forcing the second step.
    auth_env.create_user("mfaaud", "mfaaudpw1")
    token = auth_env.login("mfaaud", "mfaaudpw1")
    auth_env.enable_totp("mfaaud", "mfaaudpw1", token)
    client = auth_env.make_client()
    challenge = client.post("/auth/login", json={"username": "mfaaud", "password": "mfaaudpw1"})
    mfa_token = challenge.json()["data"]["mfa_token"]
    with caplog.at_level(logging.WARNING, logger="phantom-auth"):
        totp = client.post("/auth/mfa/verify", json={"mfa_token": mfa_token, "code": "abcdef"})
        backup = client.post("/auth/totp/backup", json={"mfa_token": mfa_token, "code": "zzzzzzzz"})
    assert (totp.status_code, backup.status_code) == (401, 401)
    user_id = auth_env.db.get_user_by_username("mfaaud").id
    failed = [row for row in auth_env.db.get_audit_logs()
              if row["action"] in ("mfa_failed", "backup_code_failed")]
    assert sorted(row["action"] for row in failed) == ["backup_code_failed", "mfa_failed"]
    assert {row["user_id"] for row in failed} == {account(user_id, "mfaaud")}
    assert service_lines(caplog) == []


def test_audit_log_on_successful_login(auth_env, caplog):
    auth_env.create_user("auditok", "auditpw12")
    client = auth_env.make_client()
    with caplog.at_level(logging.WARNING, logger="phantom-auth"):
        client.post("/auth/login", json={"username": "auditok", "password": "auditpw12"})
    logs = auth_env.db.get_audit_logs()
    assert any(l["action"] == "login_success" for l in logs)
    assert service_lines(caplog) == []


def test_audit_log_on_user_create(auth_env):
    auth_env.create_user("audadmin", "adminpw12", role="superadmin")
    token = auth_env.login("audadmin", "adminpw12")
    client = auth_env.make_client()
    client.post(
        "/auth/users",
        json={"username": "newaudit", "password": "NewPw1234!"},
        headers=auth_env.bearer(token),
    )
    logs = auth_env.db.get_audit_logs()
    assert any(l["action"] == "user_created" for l in logs)


def test_audit_log_on_logout(auth_env):
    auth_env.create_user("logoutaud", "logpw1234")
    token = auth_env.login("logoutaud", "logpw1234")
    client = auth_env.make_client()
    client.post("/auth/logout", headers=auth_env.bearer(token))
    logs = auth_env.db.get_audit_logs()
    assert any(l["action"] == "logout" for l in logs)


def test_audit_log_on_totp_enable(auth_env):
    auth_env.create_user("totpaud", "totppw123")
    token = auth_env.login("totpaud", "totppw123")
    auth_env.enable_totp("totpaud", "totppw123", token)
    logs = auth_env.db.get_audit_logs()
    assert any(l["action"] == "totp_setup_started" for l in logs)
    assert any(l["action"] == "totp_enabled" for l in logs)


# ── GET /auth/audit ───────────────────────────────────────────────


def test_audit_endpoint_requires_auth(auth_env):
    client = auth_env.make_client()
    resp = client.get("/auth/audit")
    assert resp.status_code == 401


def test_audit_endpoint_admin_forbidden(auth_env):
    auth_env.create_user("regular", "RegPw1234!")
    token = auth_env.login("regular", "RegPw1234!")
    client = auth_env.make_client()
    resp = client.get("/auth/audit", headers=auth_env.bearer(token))
    assert resp.status_code == 403


def test_audit_endpoint_superadmin_ok(auth_env):
    auth_env.create_user("sadmin", "SAdminPw1!", role="superadmin")
    token = auth_env.login("sadmin", "SAdminPw1!")
    client = auth_env.make_client()
    resp = client.get("/auth/audit", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    data = resp.json()
    assert data["ok"] is True
    page = data["data"]
    assert "items" in page
    assert "total" in page
    assert "page" in page
    assert "limit" in page
    assert "pages" in page
    assert "order" in page
    assert "sort_by" in page


def test_audit_endpoint_pagination_defaults(auth_env):
    auth_env.create_user("padmin", "PAdminPw1!", role="superadmin")
    token = auth_env.login("padmin", "PAdminPw1!")
    client = auth_env.make_client()
    resp = client.get("/auth/audit", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    page = resp.json()["data"]
    assert page["page"] == 1
    assert page["limit"] == 25


def test_audit_endpoint_pagination_params(auth_env):
    auth_env.create_user("pgadmin", "PgAdmPw1!", role="superadmin")
    token = auth_env.login("pgadmin", "PgAdmPw1!")
    # Seed 10 extra log entries
    for _ in range(10):
        auth_env.db.add_audit_log("test_event", {}, ip_address="0.0.0.0")
    client = auth_env.make_client()
    resp = client.get("/auth/audit?page=1&limit=5", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    page = resp.json()["data"]
    assert page["limit"] == 5
    assert len(page["items"]) <= 5


def test_audit_endpoint_filter_action(auth_env):
    auth_env.create_user("faction", "FActPw12!", role="superadmin")
    token = auth_env.login("faction", "FActPw12!")
    auth_env.db.add_audit_log("custom_event", {}, ip_address="1.0.0.1")
    auth_env.db.add_audit_log("other_event", {}, ip_address="1.0.0.1")
    client = auth_env.make_client()
    resp = client.get("/auth/audit?action=custom_event", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    items = resp.json()["data"]["items"]
    assert all(i["action"] == "custom_event" for i in items)


def test_audit_endpoint_filter_username(auth_env):
    auth_env.create_user("sadmin2", "SAdm2Pw1!", role="superadmin")
    target = auth_env.create_user("target_user", "TargetPw1!")
    auth_env.db.add_audit_log("login_success", {}, user_id=target.id, ip_address="2.0.0.1")
    auth_env.db.add_audit_log("login_success", {}, ip_address="2.0.0.1")  # no user_id
    token = auth_env.login("sadmin2", "SAdm2Pw1!")
    client = auth_env.make_client()
    resp = client.get("/auth/audit?username=target_user", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    items = resp.json()["data"]["items"]
    assert all(i["username"] == "target_user" for i in items)


def test_audit_endpoint_filter_ip(auth_env):
    auth_env.create_user("ipadmin", "IpAdmPw1!", role="superadmin")
    auth_env.db.add_audit_log("login_failed", {}, ip_address="5.5.5.5")
    auth_env.db.add_audit_log("login_failed", {}, ip_address="6.6.6.6")
    token = auth_env.login("ipadmin", "IpAdmPw1!")
    client = auth_env.make_client()
    resp = client.get("/auth/audit?ip=5.5.5.5", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    items = resp.json()["data"]["items"]
    assert all(i["ip_address"] == "5.5.5.5" for i in items)


def test_audit_endpoint_entry_schema(auth_env):
    auth_env.create_user("schemaadmin", "SchmAdmPw1!", role="superadmin")
    target = auth_env.create_user("schemauser", "SchUsrPw1!")
    auth_env.db.add_audit_log(
        "login_success", {"username": "schemauser"}, user_id=target.id, ip_address="7.7.7.7"
    )
    token = auth_env.login("schemaadmin", "SchmAdmPw1!")
    client = auth_env.make_client()
    resp = client.get("/auth/audit?username=schemauser", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    item = resp.json()["data"]["items"][0]
    assert "id" in item
    assert "user_id" in item
    assert "username" in item
    assert item["username"] == "schemauser"
    assert "action" in item
    assert "detail" in item
    assert isinstance(item["detail"], dict)
    assert "ip_address" in item
    assert "timestamp" in item


def test_audit_endpoint_limit_max(auth_env):
    auth_env.create_user("limitadmin", "LimAdmPw1!", role="superadmin")
    token = auth_env.login("limitadmin", "LimAdmPw1!")
    client = auth_env.make_client()
    resp = client.get("/auth/audit?limit=200", headers=auth_env.bearer(token))
    assert resp.status_code == 422  # limit > 100 rejected


def test_audit_endpoint_order_desc_default(auth_env):
    """Default order=desc — response echoes order and sort_by."""
    auth_env.create_user("oadmin", "OrdAdmPw1!", role="superadmin")
    for i in range(3):
        auth_env.db.add_audit_log("login_success", {"i": i}, ip_address="10.1.0.1")
    token = auth_env.login("oadmin", "OrdAdmPw1!")
    client = auth_env.make_client()
    resp = client.get("/auth/audit", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    page = resp.json()["data"]
    assert page["order"] == "desc"
    assert page["sort_by"] == "timestamp"
    ids = [i["id"] for i in page["items"]]
    assert ids == sorted(ids, reverse=True)


def test_audit_endpoint_order_asc(auth_env):
    """order=asc — oldest entry first, response echoes asc."""
    auth_env.create_user("oadmin2", "OrdAdm2Pw!", role="superadmin")
    for i in range(3):
        auth_env.db.add_audit_log("logout", {"i": i}, ip_address="10.2.0.1")
    token = auth_env.login("oadmin2", "OrdAdm2Pw!")
    client = auth_env.make_client()
    resp = client.get("/auth/audit?order=asc", headers=auth_env.bearer(token))
    assert resp.status_code == 200
    page = resp.json()["data"]
    assert page["order"] == "asc"
    ids = [i["id"] for i in page["items"]]
    assert ids == sorted(ids)


def test_audit_endpoint_order_invalid_rejected(auth_env):
    """order values other than 'asc'/'desc' are rejected with 422."""
    auth_env.create_user("oadmin3", "OrdAdm3Pw!", role="superadmin")
    token = auth_env.login("oadmin3", "OrdAdm3Pw!")
    client = auth_env.make_client()
    resp = client.get("/auth/audit?order=random", headers=auth_env.bearer(token))
    assert resp.status_code == 422


def test_audit_endpoint_sort_by_invalid_rejected(auth_env):
    """sort_by values other than 'timestamp' are rejected with 422."""
    auth_env.create_user("oadmin4", "OrdAdm4Pw!", role="superadmin")
    token = auth_env.login("oadmin4", "OrdAdm4Pw!")
    client = auth_env.make_client()
    resp = client.get("/auth/audit?sort_by=username", headers=auth_env.bearer(token))
    assert resp.status_code == 422
