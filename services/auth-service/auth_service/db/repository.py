"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.

Auth database repository — user, session, TOTP backup, audit CRUD.
"""

from __future__ import annotations

import json
import sqlite3
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from auth_service.db.connection import open_connection
from auth_service.errors import AuthDatabaseError


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass(frozen=True, slots=True)
class UserRow:
    """User record from database."""

    id: str
    username: str
    password_hash: str
    role: str
    totp_secret: str | None
    created_at: str
    updated_at: str


@dataclass(frozen=True, slots=True)
class SessionRow:
    """Session record from database."""

    id: str
    user_id: str
    token_jti: str
    token_hash: str
    issued_at: str
    expires_at: str
    last_activity_at: str
    revoked: bool


class AuthDB:
    """Auth database — synchronous SQLite operations."""

    __slots__ = ("_conn",)

    def __init__(self, conn: sqlite3.Connection) -> None:
        self._conn = conn

    def close(self) -> None:
        self._conn.close()

    # ── Users ────────────────────────────────────────────────────

    def create_user(self, username: str, password_hash: str, role: str = "admin") -> UserRow:
        """Create a new user. Raises AuthDatabaseError on duplicate."""
        user_id = uuid.uuid4().hex
        now = _now_iso()
        try:
            self._conn.execute(
                "INSERT INTO users (id, username, password_hash, role, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (user_id, username, password_hash, role, now, now),
            )
            self._conn.commit()
        except sqlite3.IntegrityError as exc:
            raise AuthDatabaseError(f"User already exists: {username}") from exc
        return UserRow(
            id=user_id,
            username=username,
            password_hash=password_hash,
            role=role,
            totp_secret=None,
            created_at=now,
            updated_at=now,
        )

    def get_user_by_username(self, username: str) -> UserRow | None:
        """Fetch user by username."""
        row = self._conn.execute(
            "SELECT id, username, password_hash, role, totp_secret, created_at, updated_at "
            "FROM users WHERE username = ?",
            (username,),
        ).fetchone()
        if row is None:
            return None
        return UserRow(
            id=row["id"],
            username=row["username"],
            password_hash=row["password_hash"],
            role=row["role"],
            totp_secret=row["totp_secret"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        )

    def get_user_by_id(self, user_id: str) -> UserRow | None:
        """Fetch user by ID."""
        row = self._conn.execute(
            "SELECT id, username, password_hash, role, totp_secret, created_at, updated_at "
            "FROM users WHERE id = ?",
            (user_id,),
        ).fetchone()
        if row is None:
            return None
        return UserRow(
            id=row["id"],
            username=row["username"],
            password_hash=row["password_hash"],
            role=row["role"],
            totp_secret=row["totp_secret"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        )

    def list_users(self) -> list[UserRow]:
        """List all users."""
        rows = self._conn.execute(
            "SELECT id, username, password_hash, role, totp_secret, created_at, updated_at "
            "FROM users ORDER BY created_at"
        ).fetchall()
        return [
            UserRow(
                id=r["id"],
                username=r["username"],
                password_hash=r["password_hash"],
                role=r["role"],
                totp_secret=r["totp_secret"],
                created_at=r["created_at"],
                updated_at=r["updated_at"],
            )
            for r in rows
        ]

    def delete_user(self, username: str) -> bool:
        """Delete user by username. Returns True if deleted."""
        cursor = self._conn.execute(
            "DELETE FROM users WHERE username = ?", (username,)
        )
        self._conn.commit()
        return cursor.rowcount > 0

    def update_password(self, username: str, password_hash: str) -> bool:
        """Update user password. Returns True if updated."""
        now = _now_iso()
        cursor = self._conn.execute(
            "UPDATE users SET password_hash = ?, updated_at = ? WHERE username = ?",
            (password_hash, now, username),
        )
        self._conn.commit()
        return cursor.rowcount > 0

    # ── TOTP ─────────────────────────────────────────────────────

    def set_totp_secret(self, user_id: str, secret: str | None) -> bool:
        """Set or clear TOTP secret for a user."""
        now = _now_iso()
        cursor = self._conn.execute(
            "UPDATE users SET totp_secret = ?, updated_at = ? WHERE id = ?",
            (secret, now, user_id),
        )
        self._conn.commit()
        return cursor.rowcount > 0

    def store_backup_codes(self, user_id: str, code_hashes: list[str]) -> None:
        """Store hashed backup codes, replacing any existing ones."""
        self._conn.execute(
            "DELETE FROM totp_backup_codes WHERE user_id = ?", (user_id,)
        )
        for code_hash in code_hashes:
            self._conn.execute(
                "INSERT INTO totp_backup_codes (user_id, code_hash) VALUES (?, ?)",
                (user_id, code_hash),
            )
        self._conn.commit()

    def verify_backup_code(self, user_id: str, code_hash: str) -> bool:
        """Check backup code and mark as used. Returns True if valid."""
        row = self._conn.execute(
            "SELECT id FROM totp_backup_codes "
            "WHERE user_id = ? AND code_hash = ? AND used = 0",
            (user_id, code_hash),
        ).fetchone()
        if row is None:
            return False
        self._conn.execute(
            "UPDATE totp_backup_codes SET used = 1 WHERE id = ?", (row["id"],)
        )
        self._conn.commit()
        return True

    def clear_backup_codes(self, user_id: str) -> None:
        """Delete all backup codes for a user."""
        self._conn.execute(
            "DELETE FROM totp_backup_codes WHERE user_id = ?", (user_id,)
        )
        self._conn.commit()

    def count_remaining_backup_codes(self, user_id: str) -> int:
        """Count unused backup codes."""
        row = self._conn.execute(
            "SELECT COUNT(*) AS cnt FROM totp_backup_codes "
            "WHERE user_id = ? AND used = 0",
            (user_id,),
        ).fetchone()
        return row["cnt"]

    # ── Sessions ─────────────────────────────────────────────────

    def create_session(
        self,
        user_id: str,
        token_jti: str,
        token_hash: str,
        issued_at: str,
        expires_at: str,
    ) -> SessionRow:
        """Create a new session record."""
        session_id = uuid.uuid4().hex
        self._conn.execute(
            "INSERT INTO sessions "
            "(id, user_id, token_jti, token_hash, issued_at, expires_at, last_activity_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (session_id, user_id, token_jti, token_hash, issued_at, expires_at, issued_at),
        )
        self._conn.commit()
        return SessionRow(
            id=session_id,
            user_id=user_id,
            token_jti=token_jti,
            token_hash=token_hash,
            issued_at=issued_at,
            expires_at=expires_at,
            last_activity_at=issued_at,
            revoked=False,
        )

    def get_session_by_jti(self, jti: str) -> SessionRow | None:
        """Fetch session by JTI."""
        row = self._conn.execute(
            "SELECT id, user_id, token_jti, token_hash, issued_at, expires_at, "
            "last_activity_at, revoked FROM sessions WHERE token_jti = ?",
            (jti,),
        ).fetchone()
        if row is None:
            return None
        return SessionRow(
            id=row["id"],
            user_id=row["user_id"],
            token_jti=row["token_jti"],
            token_hash=row["token_hash"],
            issued_at=row["issued_at"],
            expires_at=row["expires_at"],
            last_activity_at=row["last_activity_at"],
            revoked=bool(row["revoked"]),
        )

    def is_session_valid(self, jti: str) -> bool:
        """Check if session exists and is not revoked."""
        row = self._conn.execute(
            "SELECT revoked FROM sessions WHERE token_jti = ?", (jti,)
        ).fetchone()
        if row is None:
            return False
        return not bool(row["revoked"])

    def update_last_activity(self, jti: str) -> None:
        """Update last_activity_at for a session."""
        now = _now_iso()
        self._conn.execute(
            "UPDATE sessions SET last_activity_at = ? WHERE token_jti = ?",
            (now, jti),
        )
        self._conn.commit()

    def revoke_session(self, jti: str) -> bool:
        """Revoke a session by JTI. Returns True if revoked."""
        cursor = self._conn.execute(
            "UPDATE sessions SET revoked = 1 WHERE token_jti = ? AND revoked = 0",
            (jti,),
        )
        self._conn.commit()
        return cursor.rowcount > 0

    def revoke_user_sessions(self, user_id: str) -> int:
        """Revoke all sessions for a user. Returns count revoked."""
        cursor = self._conn.execute(
            "UPDATE sessions SET revoked = 1 WHERE user_id = ? AND revoked = 0",
            (user_id,),
        )
        self._conn.commit()
        return cursor.rowcount

    # ── Audit ────────────────────────────────────────────────────

    def add_audit_log(
        self,
        action: str,
        detail: dict | None = None,
        user_id: str | None = None,
        ip_address: str = "",
    ) -> None:
        """Append an audit log entry."""
        self._conn.execute(
            "INSERT INTO audit_log (user_id, action, detail, ip_address, timestamp) "
            "VALUES (?, ?, ?, ?, ?)",
            (
                user_id,
                action,
                json.dumps(detail or {}),
                ip_address,
                _now_iso(),
            ),
        )
        self._conn.commit()

    def get_audit_logs(self, limit: int = 100) -> list[dict]:
        """Get recent audit log entries."""
        rows = self._conn.execute(
            "SELECT id, user_id, action, detail, ip_address, timestamp "
            "FROM audit_log ORDER BY id DESC LIMIT ?",
            (limit,),
        ).fetchall()
        return [dict(r) for r in rows]

    def get_audit_logs_paginated(
        self,
        page: int = 1,
        limit: int = 25,
        action: str | None = None,
        username: str | None = None,
        ip: str | None = None,
        order: str = "desc",
        sort_by: str = "timestamp",
    ) -> dict:
        """Get audit log entries with server-side pagination, filtering and ordering.

        Joins with users table to resolve username from user_id.
        sort_by is reserved for future multi-column support; currently only 'timestamp'.
        Returns: { items, total, page, limit, pages, order, sort_by }
        """
        # Normalise and guard order / sort_by to prevent SQL injection
        safe_order = "DESC" if order.lower() != "asc" else "ASC"
        # Only timestamp (al.id proxy) is supported for now
        safe_sort_key = "al.id"

        # Build WHERE clause dynamically
        conditions: list[str] = []
        params: list[object] = []

        if action is not None:
            conditions.append("al.action = ?")
            params.append(action)
        if username is not None:
            conditions.append("u.username = ?")
            params.append(username)
        if ip is not None:
            conditions.append("al.ip_address = ?")
            params.append(ip)

        where = ("WHERE " + " AND ".join(conditions)) if conditions else ""

        base_query = (
            "FROM audit_log al "
            "LEFT JOIN users u ON al.user_id = u.id "
            f"{where}"
        )

        # Single query with COUNT(*) OVER() to get total and rows atomically,
        # avoiding a race between separate COUNT and SELECT statements.
        offset = (page - 1) * limit
        rows = self._conn.execute(
            f"SELECT al.id, al.user_id, u.username, al.action, al.detail, "
            f"al.ip_address, al.timestamp, COUNT(*) OVER() AS _total "
            f"{base_query} "
            f"ORDER BY {safe_sort_key} {safe_order} LIMIT ? OFFSET ?",
            [*params, limit, offset],
        ).fetchall()

        total = rows[0]["_total"] if rows else self._conn.execute(
            f"SELECT COUNT(*) {base_query}", params
        ).fetchone()[0]

        import math
        pages = math.ceil(total / limit) if total > 0 else 1

        items = []
        for r in rows:
            row_dict = dict(r)
            row_dict.pop("_total", None)
            try:
                row_dict["detail"] = json.loads(row_dict["detail"] or "{}")
            except (json.JSONDecodeError, TypeError):
                row_dict["detail"] = {}
            items.append(row_dict)

        return {
            "items": items,
            "total": total,
            "page": page,
            "limit": limit,
            "pages": pages,
            "order": safe_order.lower(),
            "sort_by": sort_by,
        }


def resolve_db_path(db_dir: str) -> str:
    """Resolve and validate auth.db path. Raises if not found."""
    path = Path(db_dir)
    db_file = path / "auth.db"
    if not db_file.exists():
        raise AuthDatabaseError(
            f"Auth database not found: {db_file} — run tools/setup.sh first"
        )
    return str(db_file)


def open_auth_db(db_path: str) -> AuthDB:
    """Open a per-request AuthDB connection."""
    conn = open_connection(db_path)
    return AuthDB(conn)


def bootstrap_auth_db(db_dir: str) -> tuple[AuthDB, str]:
    """Create auth.db with schema. Returns (AuthDB, db_path).

    Used by tools/setup.sh bootstrap and test fixtures.
    """
    path = Path(db_dir)
    path.mkdir(parents=True, exist_ok=True)
    db_path = str(path / "auth.db")
    conn = open_connection(db_path)
    return AuthDB(conn), db_path
