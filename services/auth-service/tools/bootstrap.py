"""
Bootstrap: generate Ed25519 keys, create auth.db, create initial admin user.
Standalone script — no auth_service imports. Runs inside container via tools/setup.sh.
"""

from __future__ import annotations

import argparse
import secrets
import sqlite3
import string
import uuid
from datetime import datetime, timezone
from pathlib import Path

from nacl.pwhash import argon2id
from nacl.signing import SigningKey

_PASSWORD_LENGTH = 32
_PASSWORD_ALPHABET = string.ascii_letters + string.digits + string.punctuation

_SCHEMA = """\
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS users (
    id            TEXT PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL DEFAULT 'admin',
    totp_secret   TEXT,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS totp_backup_codes (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash TEXT NOT NULL,
    used      INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_backup_user ON totp_backup_codes(user_id);

CREATE TABLE IF NOT EXISTS sessions (
    id               TEXT PRIMARY KEY,
    user_id          TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_jti        TEXT NOT NULL UNIQUE,
    token_hash       TEXT NOT NULL,
    issued_at        TEXT NOT NULL,
    expires_at       TEXT NOT NULL,
    last_activity_at TEXT NOT NULL,
    revoked          INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_sessions_jti ON sessions(token_jti);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);

CREATE TABLE IF NOT EXISTS audit_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    TEXT,
    action     TEXT NOT NULL,
    detail     TEXT NOT NULL DEFAULT '{}',
    ip_address TEXT NOT NULL DEFAULT '',
    timestamp  TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_log(action);
CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(timestamp);
"""


def _generate_password() -> str:
    return "".join(secrets.choice(_PASSWORD_ALPHABET) for _ in range(_PASSWORD_LENGTH))


def main() -> None:
    parser = argparse.ArgumentParser(description="Bootstrap auth service")
    parser.add_argument("--secrets-dir", required=True)
    parser.add_argument("--db-dir", required=True)
    parser.add_argument("--admin-username", default="admin")
    args = parser.parse_args()

    secrets_dir = Path(args.secrets_dir)
    db_dir = Path(args.db_dir)

    # 1. Generate Ed25519 keypair
    sk = SigningKey.generate()
    vk = sk.verify_key
    signing_hex = sk.encode().hex()
    verify_hex = vk.encode().hex()

    secrets_dir.mkdir(parents=True, exist_ok=True)
    (secrets_dir / "auth_signing_key").write_text(signing_hex)
    (secrets_dir / "auth_verify_key").write_text(verify_hex)

    # 2. Generate admin password
    password = _generate_password()
    password_file = secrets_dir / ".admin_password"
    password_file.write_text(password)

    # 3. Create database + schema
    db_dir.mkdir(parents=True, exist_ok=True)
    db_path = str(db_dir / "auth.db")
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA wal_autocheckpoint = 1")
    conn.execute("PRAGMA foreign_keys = ON")
    conn.executescript(_SCHEMA)

    # 4. Create admin user
    user_id = uuid.uuid4().hex
    now = datetime.now(timezone.utc).isoformat()
    pw_hash = argon2id.str(password.encode("utf-8")).decode("ascii")
    conn.execute(
        "INSERT INTO users (id, username, password_hash, role, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (user_id, args.admin_username, pw_hash, "superadmin", now, now),
    )
    conn.commit()
    conn.close()

    # 5. Output summary (setup.sh parses this)
    print(f"SIGNING_KEY={signing_hex}")
    print(f"VERIFY_KEY={verify_hex}")
    print(f"PASSWORD_FILE={password_file}")
    print(f"DB_PATH={db_dir / 'auth.db'}")
    print(f"ADMIN_USERNAME={args.admin_username}")
    print("BOOTSTRAP_OK=1")


if __name__ == "__main__":
    main()
