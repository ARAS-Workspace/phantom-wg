"""tools/bootstrap.py: the first account and its audit row, written by a script that runs alone."""

from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
from contextlib import closing
from pathlib import Path

from auth_service.audit import account, system
from auth_service.db.repository import open_auth_db

ROOT = Path(__file__).resolve().parents[2]
NAME = "first-root"


def bootstrap(tmp_path: Path) -> tuple[subprocess.CompletedProcess, Path]:
    # Run alone, as the setup tools mount it: a copy outside the tree.
    script = tmp_path / "bootstrap.py"
    script.write_bytes((ROOT / "tools/bootstrap.py").read_bytes())
    db_dir = tmp_path / "db"
    done = subprocess.run(
        [sys.executable, str(script), "--secrets-dir", str(tmp_path / "secrets"),
         "--db-dir", str(db_dir), "--admin-username", NAME],
        cwd=tmp_path, capture_output=True, text=True, check=False,
    )
    return done, db_dir / "auth.db"


def test_the_first_account_comes_with_its_audit_row(tmp_path):
    done, db_path = bootstrap(tmp_path)
    assert done.returncode == 0, done.stderr
    assert "BOOTSTRAP_OK=1" in done.stdout
    with closing(sqlite3.connect(db_path)) as conn:
        user_id, role = conn.execute("SELECT id, role FROM users WHERE username = ?", (NAME,)).fetchone()
        rows = conn.execute("SELECT user_id, action, detail, ip_address FROM audit_log").fetchall()
    assert role == "superadmin"
    assert [(r[0], r[1], json.loads(r[2]), r[3]) for r in rows] == [
        (system("bootstrap"), "user_created", {"target": account(user_id, NAME), "role": "superadmin"}, ""),
    ]


def test_the_reader_shows_the_bootstrap_as_the_actor(tmp_path):
    _, db_path = bootstrap(tmp_path)
    db = open_auth_db(str(db_path))
    try:
        entry = db.get_audit_logs_paginated()["items"][0]
    finally:
        db.close()
    assert (entry["action"], entry["user_id"], entry["username"]) == (
        "user_created", None, "system:bootstrap",
    )
