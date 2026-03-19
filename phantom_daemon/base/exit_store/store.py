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

Exit store: persistent storage for multihop exit tunnel configurations.
"""

from __future__ import annotations

import importlib.resources
import sqlite3
import uuid
from pathlib import Path
from typing import Optional

from phantom_daemon.base.errors import ExitStoreError


# ── Schema ───────────────────────────────────────────────────────

def _read_schema() -> str:
    """Read schema.sql from package resources."""
    ref = importlib.resources.files("phantom_daemon.base.exit_store").joinpath(
        "schema.sql"
    )
    return ref.read_text(encoding="utf-8")


def _connect(db_path: Path) -> sqlite3.Connection:
    """Open an existing exit store database."""
    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA wal_autocheckpoint = 1")
    return conn


def _create_store(db_path: Path) -> sqlite3.Connection:
    """Create a new exit store database with schema and defaults."""
    conn = sqlite3.connect(str(db_path))
    try:
        schema = _read_schema()
        conn.executescript(schema)
        conn.execute("PRAGMA wal_autocheckpoint = 1")

        conn.commit()
    except Exception:
        conn.close()
        raise
    return conn


# ── Helpers ──────────────────────────────────────────────────────

_EXIT_COLUMNS = (
    "id", "name", "endpoint", "address", "private_key_hex",
    "public_key_hex", "preshared_key_hex", "allowed_ips", "keepalive",
)

_EXIT_SELECT = (
    "SELECT id, name, endpoint, address, private_key_hex, "
    "public_key_hex, preshared_key_hex, allowed_ips, keepalive "
    "FROM exits"
)


def _row_to_dict(row: tuple) -> dict:
    return dict(zip(_EXIT_COLUMNS, row))


# ── ExitStore ────────────────────────────────────────────────────


class ExitStore:
    """Persistent storage for multihop exit tunnel configurations."""

    __slots__ = ("_conn", "_db_path")

    def __init__(self, conn: sqlite3.Connection, db_path: Path) -> None:
        self._conn = conn
        self._db_path = db_path

    # ── Config ───────────────────────────────────────────────────

    def is_enabled(self) -> bool:
        """Return True if multihop is enabled."""
        row = self._conn.execute(
            "SELECT value FROM config WHERE key = 'multihop_enabled'"
        ).fetchone()
        return row is not None and row[0] == "1"

    def get_active(self) -> str:
        """Return active exit name, or '' if none."""
        row = self._conn.execute(
            "SELECT value FROM config WHERE key = 'active_exit'"
        ).fetchone()
        return row[0] if row else ""

    # ── CRUD ─────────────────────────────────────────────────────

    def add_exit(
        self,
        name: str,
        *,
        endpoint: str,
        address: str,
        private_key_hex: str,
        public_key_hex: str,
        preshared_key_hex: str = "",
        allowed_ips: str = "0.0.0.0/0, ::/0",
        keepalive: int = 5,
    ) -> dict:
        """Add a new exit configuration. Raises ExitStoreError on duplicate."""
        existing = self._conn.execute(
            "SELECT 1 FROM exits WHERE name = ?", (name,)
        ).fetchone()
        if existing:
            raise ExitStoreError(f"Exit name already exists: {name}")

        exit_id = uuid.uuid4().hex
        self._conn.execute(
            "INSERT INTO exits (id, name, endpoint, address, private_key_hex, "
            "public_key_hex, preshared_key_hex, allowed_ips, keepalive) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (exit_id, name, endpoint, address, private_key_hex,
             public_key_hex, preshared_key_hex, allowed_ips, keepalive),
        )

        self._conn.commit()

        return {
            "id": exit_id,
            "name": name,
            "endpoint": endpoint,
            "address": address,
            "private_key_hex": private_key_hex,
            "public_key_hex": public_key_hex,
            "preshared_key_hex": preshared_key_hex,
            "allowed_ips": allowed_ips,
            "keepalive": keepalive,
        }

    def remove_exit(self, name: str) -> None:
        """Remove an exit configuration. Raises if active or not found."""
        active = self.get_active()
        if active == name:
            raise ExitStoreError(
                f"Cannot remove active exit: {name} — deactivate first"
            )

        row = self._conn.execute(
            "SELECT 1 FROM exits WHERE name = ?", (name,)
        ).fetchone()
        if not row:
            raise ExitStoreError(f"Exit not found: {name}")

        self._conn.execute("DELETE FROM exits WHERE name = ?", (name,))

        self._conn.commit()

    def get_exit(self, name: str) -> Optional[dict]:
        """Get exit by name, or None if not found."""
        row = self._conn.execute(
            f"{_EXIT_SELECT} WHERE name = ?", (name,)
        ).fetchone()
        return _row_to_dict(row) if row else None

    def list_exits(self) -> list[dict]:
        """List all exit configurations."""
        rows = self._conn.execute(
            f"{_EXIT_SELECT} ORDER BY rowid"
        ).fetchall()
        return [_row_to_dict(r) for r in rows]

    # ── State ────────────────────────────────────────────────────

    def activate(self, name: str) -> None:
        """Set multihop enabled and active exit name."""
        row = self._conn.execute(
            "SELECT 1 FROM exits WHERE name = ?", (name,)
        ).fetchone()
        if not row:
            raise ExitStoreError(f"Exit not found: {name}")

        self._conn.execute(
            "UPDATE config SET value = '1' WHERE key = 'multihop_enabled'"
        )
        self._conn.execute(
            "UPDATE config SET value = ? WHERE key = 'active_exit'",
            (name,),
        )

        self._conn.commit()

    def deactivate(self) -> None:
        """Clear active exit and disable multihop."""
        self._conn.execute(
            "UPDATE config SET value = '0' WHERE key = 'multihop_enabled'"
        )
        self._conn.execute(
            "UPDATE config SET value = '' WHERE key = 'active_exit'"
        )

        self._conn.commit()

    # ── Lifecycle ────────────────────────────────────────────────

    def close(self) -> None:
        """Close the database connection."""
        self._conn.close()

    def __enter__(self) -> ExitStore:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


# ── Factory ──────────────────────────────────────────────────────


def open_exit_store(db_dir: str, db_name: str = "exit.db") -> ExitStore:
    """Open or create the exit store database.

    If the database file exists → open.
    If it does not exist → create with schema + defaults.
    """
    db_dir_path = Path(db_dir)
    if not db_dir_path.is_dir():
        raise ExitStoreError(f"Database directory does not exist: {db_dir}")

    db_path = db_dir_path / db_name

    if db_path.exists():
        conn = _connect(db_path)
    else:
        conn = _create_store(db_path)

    return ExitStore(conn, db_path)
