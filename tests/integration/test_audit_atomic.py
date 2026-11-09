"""A change in auth.db and its audit row: when the row cannot be written, the change is undone."""

from __future__ import annotations

import base64
import hashlib
import hmac
import io
import sqlite3
import struct
import time
from contextlib import closing

import pytest

from auth_service.crypto.password import verify_password
from tools.add_superadmin import main as add_superadmin

PASSWORD = "Atomic-Pass-2026!"
NEW_PASSWORD = "Atomic-Next-2026!"


def refuse_audit_rows(auth_env, action: str) -> None:
    """A trigger that aborts every audit insert of one action, as a full disk or a lock would."""
    with closing(sqlite3.connect(auth_env.db_path)) as conn:
        conn.execute(
            f"CREATE TRIGGER refuse_{action} BEFORE INSERT ON audit_log "
            f"WHEN NEW.action = '{action}' BEGIN SELECT RAISE(ABORT, 'audit row refused'); END;"
        )
        conn.commit()


def sessions(auth_env, username: str) -> list[int]:
    """The revoked flag of each session of an account."""
    user_id = auth_env.db.get_user_by_username(username).id
    with closing(sqlite3.connect(auth_env.db_path)) as conn:
        return [r[0] for r in conn.execute("SELECT revoked FROM sessions WHERE user_id = ?", (user_id,))]


def totp_now(secret: str) -> str:
    mac = hmac.new(base64.b32decode(secret), struct.pack(">Q", int(time.time()) // 30), hashlib.sha1)
    digest = mac.digest()
    offset = digest[-1] & 0x0F
    return str((struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 10**6).zfill(6)


@pytest.fixture()
def client(auth_env):
    return auth_env.make_client()


# ── Login and session ────────────────────────────────────────────


def test_a_login_without_its_row_opens_no_session(auth_env, client):
    auth_env.create_user("atomic-login", PASSWORD)
    refuse_audit_rows(auth_env, "login_success")
    with pytest.raises(sqlite3.IntegrityError):
        client.post("/auth/login", json={"username": "atomic-login", "password": PASSWORD})
    assert sessions(auth_env, "atomic-login") == []


def test_a_logout_without_its_row_keeps_the_session(auth_env, client):
    auth_env.create_user("atomic-out", PASSWORD)
    headers = auth_env.bearer(auth_env.issue_token("atomic-out"))
    refuse_audit_rows(auth_env, "logout")
    with pytest.raises(sqlite3.IntegrityError):
        client.post("/auth/logout", headers=headers)
    assert sessions(auth_env, "atomic-out") == [0]


def test_an_mfa_login_without_its_rows_leaves_neither(auth_env, client):
    # mfa_success is written first; when login_success fails after it,
    # neither row nor the session stays.
    auth_env.create_user("atomic-mfa", PASSWORD)
    setup = auth_env.enable_totp("atomic-mfa", PASSWORD, auth_env.issue_token("atomic-mfa"))
    before = sessions(auth_env, "atomic-mfa")
    token = client.post("/auth/login", json={"username": "atomic-mfa", "password": PASSWORD}).json()["data"]
    refuse_audit_rows(auth_env, "login_success")
    with pytest.raises(sqlite3.IntegrityError):
        client.post("/auth/mfa/verify", json={"mfa_token": token["mfa_token"], "code": totp_now(setup["secret"])})
    assert sessions(auth_env, "atomic-mfa") == before
    assert [r for r in auth_env.db.get_audit_logs() if r["action"] == "mfa_success"] == []


def test_a_backup_code_without_its_row_stays_unspent(auth_env, client):
    auth_env.create_user("atomic-backup", PASSWORD)
    setup = auth_env.enable_totp("atomic-backup", PASSWORD, auth_env.issue_token("atomic-backup"))
    user_id = auth_env.db.get_user_by_username("atomic-backup").id
    left = auth_env.db.count_remaining_backup_codes(user_id)
    before = sessions(auth_env, "atomic-backup")
    token = client.post("/auth/login", json={"username": "atomic-backup", "password": PASSWORD}).json()["data"]
    refuse_audit_rows(auth_env, "backup_code_used")
    with pytest.raises(sqlite3.IntegrityError):
        client.post("/auth/totp/backup", json={"mfa_token": token["mfa_token"], "code": setup["backup_codes"][0]})
    assert auth_env.db.count_remaining_backup_codes(user_id) == left
    assert sessions(auth_env, "atomic-backup") == before


# ── The account's own changes ────────────────────────────────────


def test_a_password_change_without_its_row_keeps_the_password(auth_env, client):
    auth_env.create_user("atomic-pw", PASSWORD)
    headers = auth_env.bearer(auth_env.issue_token("atomic-pw"))
    change = client.post("/auth/password/verify", json={"password": PASSWORD}, headers=headers)
    refuse_audit_rows(auth_env, "password_changed")
    with pytest.raises(sqlite3.IntegrityError):
        client.post("/auth/password/change", headers=headers,
                    json={"change_token": change.json()["data"]["change_token"], "password": NEW_PASSWORD})
    assert verify_password(PASSWORD, auth_env.db.get_user_by_username("atomic-pw").password_hash)
    assert sessions(auth_env, "atomic-pw") == [0]


def test_a_totp_confirm_without_its_row_leaves_totp_off(auth_env, client):
    auth_env.create_user("atomic-totp", PASSWORD)
    headers = auth_env.bearer(auth_env.issue_token("atomic-totp"))
    setup = client.post("/auth/totp/setup", json={"password": PASSWORD}, headers=headers).json()["data"]
    refuse_audit_rows(auth_env, "totp_enabled")
    with pytest.raises(sqlite3.IntegrityError):
        client.post("/auth/totp/confirm", headers=headers,
                    json={"setup_token": setup["setup_token"], "code": totp_now(setup["secret"])})
    user = auth_env.db.get_user_by_username("atomic-totp")
    assert user.totp_secret is None
    assert auth_env.db.count_remaining_backup_codes(user.id) == 0


# ── Changes to another account ───────────────────────────────────


@pytest.fixture()
def root(auth_env):
    auth_env.create_user("atomic-root", PASSWORD, role="superadmin")
    return auth_env.bearer(auth_env.issue_token("atomic-root"))


def test_a_user_created_without_its_row_does_not_exist(auth_env, client, root):
    refuse_audit_rows(auth_env, "user_created")
    with pytest.raises(sqlite3.IntegrityError):
        client.post("/auth/users", json={"username": "atomic-new", "password": PASSWORD}, headers=root)
    assert auth_env.db.get_user_by_username("atomic-new") is None


def test_a_user_deleted_without_its_row_stays_with_its_sessions(auth_env, client, root):
    auth_env.create_user("atomic-old", PASSWORD)
    auth_env.issue_token("atomic-old")
    refuse_audit_rows(auth_env, "user_deleted")
    with pytest.raises(sqlite3.IntegrityError):
        client.delete("/auth/users/atomic-old", headers=root)
    assert auth_env.db.get_user_by_username("atomic-old") is not None
    assert sessions(auth_env, "atomic-old") == [0]


def test_a_reset_without_its_row_keeps_the_password(auth_env, client, root):
    auth_env.create_user("atomic-reset", PASSWORD)
    refuse_audit_rows(auth_env, "password_changed")
    with pytest.raises(sqlite3.IntegrityError):
        client.post("/auth/users/atomic-reset/password", json={"password": NEW_PASSWORD}, headers=root)
    assert verify_password(PASSWORD, auth_env.db.get_user_by_username("atomic-reset").password_hash)


def test_a_totp_disabled_without_its_row_stays_on(auth_env, client, root):
    auth_env.create_user("atomic-tdis", PASSWORD)
    auth_env.enable_totp("atomic-tdis", PASSWORD, auth_env.issue_token("atomic-tdis"))
    refuse_audit_rows(auth_env, "totp_disabled")
    with pytest.raises(sqlite3.IntegrityError):
        client.post("/auth/totp/disable", json={"password": PASSWORD, "username": "atomic-tdis"}, headers=root)
    assert auth_env.db.get_user_by_username("atomic-tdis").totp_secret is not None


# ── The host ─────────────────────────────────────────────────────


def test_a_host_superadmin_without_its_row_does_not_exist(auth_env):
    refuse_audit_rows(auth_env, "user_created")
    with pytest.raises(sqlite3.IntegrityError):
        add_superadmin(["--db-dir", auth_env.db_dir, "--username", "atomic-host"],
                       stdin=io.StringIO(PASSWORD + "\n"))
    assert auth_env.db.get_user_by_username("atomic-host") is None
