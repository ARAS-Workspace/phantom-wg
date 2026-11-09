"""AuthDB.atomic: the writes inside a block commit together or not at all."""

from __future__ import annotations

import sqlite3
from contextlib import closing

import pytest

from auth_service.crypto.password import hash_password


def users_seen_by_another_connection(auth_env, username: str) -> int:
    with closing(sqlite3.connect(auth_env.db_path)) as conn:
        return conn.execute("SELECT count(*) FROM users WHERE username = ?", (username,)).fetchone()[0]


def test_the_writes_of_a_block_commit_at_its_end(auth_env):
    db = auth_env.db
    with db.atomic():
        user = db.create_user("atomic-one", hash_password("pass1234!A"))
        db.add_audit_log("user_created", {}, user_id=user.id, ip_address="")
        assert users_seen_by_another_connection(auth_env, "atomic-one") == 0
    assert users_seen_by_another_connection(auth_env, "atomic-one") == 1
    assert [r["action"] for r in db.get_audit_logs()] == ["user_created"]


def test_an_error_in_the_block_rolls_its_writes_back(auth_env):
    db = auth_env.db
    with pytest.raises(RuntimeError), db.atomic():
        db.create_user("atomic-two", hash_password("pass1234!A"))
        raise RuntimeError("the audit row failed")
    assert db.get_user_by_username("atomic-two") is None
    assert users_seen_by_another_connection(auth_env, "atomic-two") == 0


def test_a_block_inside_another_joins_it(auth_env):
    db = auth_env.db
    with pytest.raises(RuntimeError), db.atomic():
        with db.atomic():
            db.create_user("atomic-three", hash_password("pass1234!A"))
        assert users_seen_by_another_connection(auth_env, "atomic-three") == 0
        raise RuntimeError("the outer block failed")
    assert db.get_user_by_username("atomic-three") is None


def test_a_write_outside_a_block_commits_at_once(auth_env):
    auth_env.db.create_user("atomic-four", hash_password("pass1234!A"))
    assert users_seen_by_another_connection(auth_env, "atomic-four") == 1
