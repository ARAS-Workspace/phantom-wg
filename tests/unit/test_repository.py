from __future__ import annotations

import pytest

from auth_service.crypto.password import hash_password
from auth_service.crypto.totp import hash_backup_code
from auth_service.errors import AuthDatabaseError


def test_create_and_get_user(auth_env):
    db = auth_env.db
    pw_hash = hash_password("testpass1")
    user = db.create_user("alice", pw_hash)
    assert user.username == "alice"
    assert user.totp_secret is None
    assert len(user.id) == 32

    fetched = db.get_user_by_username("alice")
    assert fetched is not None
    assert fetched.id == user.id


def test_create_duplicate_user(auth_env):
    db = auth_env.db
    db.create_user("bob", hash_password("pass1234"))
    with pytest.raises(AuthDatabaseError, match="already exists"):
        db.create_user("bob", hash_password("pass5678"))


def test_get_user_not_found(auth_env):
    assert auth_env.db.get_user_by_username("nobody") is None


def test_list_users(auth_env):
    db = auth_env.db
    db.create_user("u1", hash_password("password1"))
    db.create_user("u2", hash_password("password2"))
    users = db.list_users()
    assert len(users) == 2
    assert {u.username for u in users} == {"u1", "u2"}


def test_delete_user(auth_env):
    db = auth_env.db
    db.create_user("del_me", hash_password("password1"))
    assert db.delete_user("del_me") is True
    assert db.get_user_by_username("del_me") is None
    assert db.delete_user("del_me") is False


def test_update_password(auth_env):
    db = auth_env.db
    db.create_user("pwuser", hash_password("oldpass1"))
    new_hash = hash_password("newpass1")
    assert db.update_password("pwuser", new_hash) is True
    user = db.get_user_by_username("pwuser")
    assert user.password_hash == new_hash


def test_update_password_not_found(auth_env):
    assert auth_env.db.update_password("ghost", "hash") is False


def test_get_user_by_id(auth_env):
    db = auth_env.db
    user = db.create_user("byid", hash_password("password1"))
    fetched = db.get_user_by_id(user.id)
    assert fetched is not None
    assert fetched.username == "byid"
    assert db.get_user_by_id("nonexistent") is None


# ── TOTP ─────────────────────────────────────────────────────────


def test_set_totp_secret(auth_env):
    db = auth_env.db
    user = db.create_user("totpuser", hash_password("password1"))
    assert db.set_totp_secret(user.id, "JBSWY3DPEHPK3PXP") is True
    fetched = db.get_user_by_username("totpuser")
    assert fetched.totp_secret == "JBSWY3DPEHPK3PXP"


def test_clear_totp_secret(auth_env):
    db = auth_env.db
    user = db.create_user("clrtotp", hash_password("password1"))
    db.set_totp_secret(user.id, "SECRET")
    db.set_totp_secret(user.id, None)
    fetched = db.get_user_by_username("clrtotp")
    assert fetched.totp_secret is None


def test_backup_codes(auth_env):
    db = auth_env.db
    user = db.create_user("backup", hash_password("password1"))
    hashes = [hash_backup_code(f"code{i}") for i in range(8)]
    db.store_backup_codes(user.id, hashes)
    assert db.count_remaining_backup_codes(user.id) == 8

    assert db.verify_backup_code(user.id, hashes[0]) is True
    assert db.count_remaining_backup_codes(user.id) == 7

    # Same code can't be used twice
    assert db.verify_backup_code(user.id, hashes[0]) is False

    # Invalid code
    assert db.verify_backup_code(user.id, "invalid") is False


def test_clear_backup_codes(auth_env):
    db = auth_env.db
    user = db.create_user("clrback", hash_password("password1"))
    hashes = [hash_backup_code("x")]
    db.store_backup_codes(user.id, hashes)
    db.clear_backup_codes(user.id)
    assert db.count_remaining_backup_codes(user.id) == 0


def test_store_backup_codes_replaces(auth_env):
    db = auth_env.db
    user = db.create_user("replback", hash_password("password1"))
    db.store_backup_codes(user.id, [hash_backup_code("old")])
    db.store_backup_codes(user.id, [hash_backup_code("new1"), hash_backup_code("new2")])
    assert db.count_remaining_backup_codes(user.id) == 2


# ── Sessions ─────────────────────────────────────────────────────


def test_create_and_validate_session(auth_env):
    db = auth_env.db
    user = db.create_user("sess_user", hash_password("password1"))
    session = db.create_session(
        user.id, "jti-1", "tokenhash1",
        "2025-01-01T00:00:00", "2025-01-02T00:00:00",
    )
    assert session.token_jti == "jti-1"
    assert session.token_hash == "tokenhash1"
    assert db.is_session_valid("jti-1") is True


def test_get_session_by_jti(auth_env):
    db = auth_env.db
    user = db.create_user("getsess", hash_password("password1"))
    db.create_session(
        user.id, "jti-get", "thash",
        "2025-01-01T00:00:00+00:00", "2025-01-02T00:00:00+00:00",
    )
    session = db.get_session_by_jti("jti-get")
    assert session is not None
    assert session.token_hash == "thash"
    assert session.revoked is False
    assert db.get_session_by_jti("nope") is None


def test_update_last_activity(auth_env):
    db = auth_env.db
    user = db.create_user("activity", hash_password("password1"))
    db.create_session(
        user.id, "jti-act", "thash",
        "2025-01-01T00:00:00+00:00", "2025-01-02T00:00:00+00:00",
    )
    db.update_last_activity("jti-act")
    session = db.get_session_by_jti("jti-act")
    assert session.last_activity_at != session.issued_at


def test_revoke_session(auth_env):
    db = auth_env.db
    user = db.create_user("rev_user", hash_password("password1"))
    db.create_session(
        user.id, "jti-2", "thash",
        "2025-01-01T00:00:00", "2025-01-02T00:00:00",
    )
    assert db.revoke_session("jti-2") is True
    assert db.is_session_valid("jti-2") is False
    assert db.revoke_session("jti-2") is False


def test_revoke_user_sessions(auth_env):
    db = auth_env.db
    user = db.create_user("multi_sess", hash_password("password1"))
    db.create_session(user.id, "jti-a", "ha", "2025-01-01T00:00:00", "2025-01-02T00:00:00")
    db.create_session(user.id, "jti-b", "hb", "2025-01-01T00:00:00", "2025-01-02T00:00:00")
    assert db.revoke_user_sessions(user.id) == 2
    assert db.is_session_valid("jti-a") is False
    assert db.is_session_valid("jti-b") is False


def test_invalid_session(auth_env):
    assert auth_env.db.is_session_valid("nonexistent") is False


def test_cascade_delete_sessions(auth_env):
    db = auth_env.db
    user = db.create_user("cascade", hash_password("password1"))
    db.create_session(user.id, "jti-cas", "hc", "2025-01-01T00:00:00", "2025-01-02T00:00:00")
    db.delete_user("cascade")
    assert db.is_session_valid("jti-cas") is False


# ── Audit ────────────────────────────────────────────────────────


def test_audit_log(auth_env):
    db = auth_env.db
    db.add_audit_log("test_action", {"key": "value"}, user_id="uid1", ip_address="1.2.3.4")
    logs = db.get_audit_logs(limit=10)
    assert len(logs) == 1
    assert logs[0]["action"] == "test_action"
    assert logs[0]["ip_address"] == "1.2.3.4"


# ── Audit paginated ───────────────────────────────────────────────


def test_audit_paginated_basic(auth_env):
    db = auth_env.db
    for i in range(10):
        db.add_audit_log("login_success", {"i": i}, ip_address="10.0.0.1")
    result = db.get_audit_logs_paginated(page=1, limit=5)
    assert result["total"] == 10
    assert len(result["items"]) == 5
    assert result["page"] == 1
    assert result["limit"] == 5
    assert result["pages"] == 2


def test_audit_paginated_second_page(auth_env):
    db = auth_env.db
    for i in range(7):
        db.add_audit_log("logout", {}, ip_address="10.0.0.2")
    result = db.get_audit_logs_paginated(page=2, limit=5)
    assert result["total"] == 7
    assert len(result["items"]) == 2
    assert result["page"] == 2


def test_audit_paginated_filter_action(auth_env):
    db = auth_env.db
    db.add_audit_log("login_success", {}, ip_address="1.1.1.1")
    db.add_audit_log("login_failed", {}, ip_address="1.1.1.1")
    db.add_audit_log("login_success", {}, ip_address="1.1.1.1")
    result = db.get_audit_logs_paginated(action="login_success")
    assert result["total"] == 2
    assert all(r["action"] == "login_success" for r in result["items"])


def test_audit_paginated_filter_username(auth_env):
    db = auth_env.db
    user = db.create_user("filterme", hash_password("pass1234!A"))
    db.add_audit_log("login_success", {}, user_id=user.id, ip_address="2.2.2.2")
    db.add_audit_log("logout", {}, ip_address="2.2.2.2")  # no user_id
    result = db.get_audit_logs_paginated(username="filterme")
    assert result["total"] == 1
    assert result["items"][0]["username"] == "filterme"


def test_audit_paginated_filter_ip(auth_env):
    db = auth_env.db
    db.add_audit_log("login_failed", {}, ip_address="9.9.9.9")
    db.add_audit_log("login_failed", {}, ip_address="8.8.8.8")
    result = db.get_audit_logs_paginated(ip="9.9.9.9")
    assert result["total"] == 1
    assert result["items"][0]["ip_address"] == "9.9.9.9"


def test_audit_paginated_username_resolved(auth_env):
    db = auth_env.db
    user = db.create_user("resolved", hash_password("pass1234!A"))
    db.add_audit_log("login_success", {}, user_id=user.id, ip_address="3.3.3.3")
    result = db.get_audit_logs_paginated()
    entry = result["items"][0]
    assert entry["username"] == "resolved"
    assert entry["user_id"] == user.id


def _rows_of_each_actor_form(db) -> tuple[str, str]:
    """A row of each user_id form; returns the live account id and a deleted one."""
    user = db.create_user("ops-a-b", hash_password("pass1234!A"))
    gone = "f" * 32
    db.add_audit_log("new_form", {}, user_id=f"{user.id}-ops-a-b", ip_address="1.0.0.1")
    db.add_audit_log("deleted_actor", {}, user_id=f"{gone}-gone-ops", ip_address="1.0.0.1")
    db.add_audit_log("system_actor", {}, user_id="system:host", ip_address="1.0.0.1")
    db.add_audit_log("old_form", {}, user_id=user.id, ip_address="1.0.0.1")
    db.add_audit_log("no_actor", {}, ip_address="1.0.0.1")
    return user.id, gone


def test_audit_paginated_reads_each_actor_form(auth_env):
    user_id, gone = _rows_of_each_actor_form(auth_env.db)
    items = auth_env.db.get_audit_logs_paginated()["items"]
    assert {i["action"]: (i["user_id"], i["username"]) for i in items} == {
        "new_form": (user_id, "ops-a-b"),
        "deleted_actor": (gone, "gone-ops"),
        "system_actor": (None, "system:host"),
        "old_form": (user_id, "ops-a-b"),
        "no_actor": (None, None),
    }


def test_audit_paginated_username_filter_matches_the_actor_name(auth_env):
    _rows_of_each_actor_form(auth_env.db)

    def actions(name: str) -> list[str]:
        items = auth_env.db.get_audit_logs_paginated(username=name)["items"]
        return sorted(i["action"] for i in items)

    assert actions("ops-a-b") == ["new_form", "old_form"]
    assert actions("gone-ops") == ["deleted_actor"]
    assert actions("system:host") == ["system_actor"]


def test_audit_paginated_no_user_id(auth_env):
    db = auth_env.db
    db.add_audit_log("login_rate_limited", {}, ip_address="4.4.4.4")
    result = db.get_audit_logs_paginated()
    entry = result["items"][0]
    assert entry["user_id"] is None
    assert entry["username"] is None


def test_audit_paginated_empty(auth_env):
    db = auth_env.db
    result = db.get_audit_logs_paginated()
    assert result["total"] == 0
    assert result["items"] == []
    assert result["pages"] == 1


def test_audit_paginated_detail_parsed(auth_env):
    db = auth_env.db
    db.add_audit_log("test_detail", {"foo": "bar", "count": 42}, ip_address="5.5.5.5")
    result = db.get_audit_logs_paginated()
    assert result["items"][0]["detail"] == {"foo": "bar", "count": 42}


def test_audit_paginated_order_default_desc(auth_env):
    """Default order is desc — most recent entry is first."""
    db = auth_env.db
    db.add_audit_log("login_success", {"seq": 1}, ip_address="1.0.0.1")
    db.add_audit_log("login_success", {"seq": 2}, ip_address="1.0.0.1")
    db.add_audit_log("login_success", {"seq": 3}, ip_address="1.0.0.1")
    result = db.get_audit_logs_paginated(order="desc")
    ids = [r["id"] for r in result["items"]]
    assert ids == sorted(ids, reverse=True)
    assert result["order"] == "desc"
    assert result["sort_by"] == "timestamp"


def test_audit_paginated_order_asc(auth_env):
    """order=asc — oldest entry is first."""
    db = auth_env.db
    db.add_audit_log("logout", {"seq": 1}, ip_address="2.0.0.1")
    db.add_audit_log("logout", {"seq": 2}, ip_address="2.0.0.1")
    db.add_audit_log("logout", {"seq": 3}, ip_address="2.0.0.1")
    result = db.get_audit_logs_paginated(order="asc")
    ids = [r["id"] for r in result["items"]]
    assert ids == sorted(ids)
    assert result["order"] == "asc"


def test_audit_paginated_order_echoed_in_response(auth_env):
    """order and sort_by are always echoed back in the response."""
    db = auth_env.db
    db.add_audit_log("login_failed", {}, ip_address="3.0.0.1")
    for order_val in ("asc", "desc"):
        result = db.get_audit_logs_paginated(order=order_val)
        assert result["order"] == order_val
        assert result["sort_by"] == "timestamp"


def test_audit_paginated_invalid_order_defaults_desc(auth_env):
    """Any unrecognised order value safely defaults to DESC."""
    db = auth_env.db
    db.add_audit_log("mfa_success", {}, ip_address="4.0.0.1")
    db.add_audit_log("mfa_success", {}, ip_address="4.0.0.1")
    result = db.get_audit_logs_paginated(order="random_value")
    ids = [r["id"] for r in result["items"]]
    assert ids == sorted(ids, reverse=True)
    assert result["order"] == "desc"
