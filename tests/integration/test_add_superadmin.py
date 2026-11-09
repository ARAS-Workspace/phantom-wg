"""tools/add_superadmin.py: a superadmin from the host, the password on stdin only."""

from __future__ import annotations

import io
import json
from pathlib import Path

import pytest

from auth_service.audit import account
from auth_service.crypto.password import verify_password
from tools.add_superadmin import EXIT_CODES, main

NAME = "host-root"
PASSWORD = "Host-Root-Pass-2026!"


class Terminal(io.StringIO):
    """stdin as an interactive terminal."""

    def isatty(self) -> bool:
        return True


def run(db_dir: str, capsys, *, username: str = NAME, password: str = PASSWORD,
        stdin: io.StringIO | None = None, extra: tuple[str, ...] = ()) -> tuple[int, str]:
    source = io.StringIO(password + "\n") if stdin is None else stdin
    try:
        code = main(["--db-dir", db_dir, "--username", username, *extra], stdin=source)
    except SystemExit as stop:
        code = stop.code
    captured = capsys.readouterr()
    return code, captured.out + captured.err


def superadmins(auth_env) -> list[str]:
    return sorted(user.username for user in auth_env.db.list_users() if user.role == "superadmin")


# ── Created ──────────────────────────────────────────────────────


def test_creates_a_superadmin(auth_env, capsys):
    code, output = run(auth_env.db_dir, capsys)
    assert code == 0
    assert output == f"SUPERADMIN_CREATED={NAME}\n"
    user = auth_env.db.get_user_by_username(NAME)
    assert user.role == "superadmin"
    assert verify_password(PASSWORD, user.password_hash)


def test_the_audit_log_names_the_host(auth_env, capsys):
    run(auth_env.db_dir, capsys)
    target = account(auth_env.db.get_user_by_username(NAME).id, NAME)
    created = [row for row in auth_env.db.get_audit_logs() if row["action"] == "user_created"]
    assert [(row["user_id"], json.loads(row["detail"])) for row in created] == [
        ("system:host", {"target": target, "role": "superadmin"}),
    ]
    entry = auth_env.db.get_audit_logs_paginated(action="user_created")["items"][0]
    assert (entry["user_id"], entry["username"]) == (None, "system:host")


def test_the_superadmin_logs_in_and_holds_its_routes(auth_env, capsys):
    run(auth_env.db_dir, capsys)
    token = auth_env.login(NAME, PASSWORD)
    client = auth_env.make_client()
    me = client.get("/auth/me", headers=auth_env.bearer(token))
    assert me.json()["data"]["role"] == "superadmin"
    assert client.get("/auth/users", headers=auth_env.bearer(token)).status_code == 200


def test_a_trailing_carriage_return_is_not_part_of_the_password(auth_env, capsys):
    code, _ = run(auth_env.db_dir, capsys, stdin=io.StringIO(PASSWORD + "\r\n"))
    assert code == 0
    assert verify_password(PASSWORD, auth_env.db.get_user_by_username(NAME).password_hash)


# ── Refused ──────────────────────────────────────────────────────


def test_a_terminal_is_refused_before_it_is_read(auth_env, capsys):
    terminal = Terminal(PASSWORD + "\n")
    code, output = run(auth_env.db_dir, capsys, stdin=terminal)
    assert code == EXIT_CODES["STDIN_IS_A_TERMINAL"]
    assert output == "STDIN_IS_A_TERMINAL\n"
    assert terminal.tell() == 0
    assert NAME not in superadmins(auth_env)


@pytest.mark.parametrize("password", [
    "Ab1!xyz",              # seven characters
    "nouppercase-2026!",
    "NOLOWERCASE-2026!",
    "No-Digits-Here!",
    "NoSpecialChar2026",
    "Ab1!" * 65,            # 260 characters
    "",
])
def test_a_password_outside_the_policy_is_refused(auth_env, capsys, password):
    code, output = run(auth_env.db_dir, capsys, password=password)
    assert (code, output) == (EXIT_CODES["WEAK_PASSWORD"], "WEAK_PASSWORD\n")
    assert auth_env.db.get_user_by_username(NAME) is None


@pytest.mark.parametrize("username", ["bad name", "", "x" * 65, "root;drop"])
def test_a_name_outside_the_api_rule_is_refused(auth_env, capsys, username):
    code, output = run(auth_env.db_dir, capsys, username=username)
    assert (code, output) == (EXIT_CODES["INVALID_USERNAME"], "INVALID_USERNAME\n")
    assert superadmins(auth_env) == []


def test_an_existing_name_is_refused_and_kept(auth_env, capsys):
    auth_env.create_user(NAME, "Other-Pass-2026!", role="admin")
    before = auth_env.db.get_user_by_username(NAME)
    code, output = run(auth_env.db_dir, capsys)
    assert (code, output) == (EXIT_CODES["USER_ALREADY_EXISTS"], "USER_ALREADY_EXISTS\n")
    after = auth_env.db.get_user_by_username(NAME)
    assert (after.role, after.password_hash) == (before.role, before.password_hash)


def test_a_missing_database_is_refused_and_not_created(tmp_path, capsys):
    db_dir = tmp_path / "auth"
    db_dir.mkdir()
    code, output = run(str(db_dir), capsys)
    assert (code, output) == (EXIT_CODES["DATABASE_NOT_FOUND"], "DATABASE_NOT_FOUND\n")
    assert list(Path(db_dir).iterdir()) == []


def test_a_password_argument_is_refused_without_its_value(auth_env, capsys):
    code, output = run(auth_env.db_dir, capsys, extra=("--password", PASSWORD))
    assert (code, output) == (EXIT_CODES["USAGE"], "USAGE\n")
    assert auth_env.db.get_user_by_username(NAME) is None


# ── The password is never printed ────────────────────────────────


@pytest.mark.parametrize("case", ["created", "weak", "bad name", "existing", "missing database"])
def test_the_password_is_never_printed(auth_env, capsys, tmp_path, case):
    password, username, db_dir = PASSWORD, NAME, auth_env.db_dir
    if case == "weak":
        password = "weakpassword-without-rules"
    elif case == "bad name":
        username = "bad name"
    elif case == "existing":
        auth_env.create_user(NAME, "Other-Pass-2026!", role="admin")
    elif case == "missing database":
        db_dir = str(tmp_path)
    _, output = run(db_dir, capsys, username=username, password=password)
    assert password not in output
