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

SQLite Online Backup API based export/import for wallet.db and exit.db.

Export creates a portable .tar containing:
    wallet.db       — IP pool, clients, DNS, subnet config
    exit.db         — Multihop exit tunnel configurations
    manifest.json   — Metadata: version, timestamp, counts

Import validates, integrity-checks, and restores both databases
from a previously exported .tar file.
"""

from __future__ import annotations

import json
import shutil
import sqlite3
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from phantom_daemon.base.errors import BackupError

MANIFEST_VERSION = "1.0"
_REQUIRED_MEMBERS = {"wallet.db", "exit.db", "manifest.json"}

# Expected schema — table name → required column set
_WALLET_SCHEMA = {
    "config": {"key", "value"},
    "users": {
        "ipv4_address", "ipv6_address", "id", "name",
        "private_key_hex", "public_key_hex", "preshared_key_hex",
        "created_at", "updated_at",
    },
}

_EXIT_SCHEMA = {
    "config": {"key", "value"},
    "exits": {
        "id", "name", "endpoint", "address",
        "private_key_hex", "public_key_hex", "preshared_key_hex",
        "allowed_ips", "keepalive",
    },
}


# ── Export ────────────────────────────────────────────────────────


def create_backup_tar(
    wallet_conn: sqlite3.Connection,
    exit_conn: sqlite3.Connection,
) -> Path:
    """Create a portable backup tar from live database connections.

    Uses SQLite Online Backup API — WAL-safe, no exclusive locks.
    Returns the path to the temporary .tar file.
    Caller is responsible for cleanup.
    """
    tmp_dir = Path(tempfile.mkdtemp(prefix="phantom-backup-"))

    try:
        # Backup wallet.db
        wallet_dst = sqlite3.connect(str(tmp_dir / "wallet.db"))
        wallet_conn.backup(wallet_dst)
        wallet_dst.close()

        # Backup exit.db — reset multihop state to defaults so restore
        # never leaves the daemon with an enabled-but-unconfigured exit tunnel.
        exit_dst = sqlite3.connect(str(tmp_dir / "exit.db"))
        exit_conn.backup(exit_dst)
        exit_dst.execute(
            "UPDATE config SET value = '0' WHERE key = 'multihop_enabled'"
        )
        exit_dst.execute(
            "UPDATE config SET value = '' WHERE key = 'active_exit'"
        )
        exit_dst.commit()
        exit_dst.close()

        # Build manifest from backed-up copies
        manifest = _build_manifest(tmp_dir / "wallet.db", tmp_dir / "exit.db")
        (tmp_dir / "manifest.json").write_text(
            json.dumps(manifest, indent=2), encoding="utf-8"
        )

        # Pack into tar
        tar_path = tmp_dir / "backup.tar"
        with tarfile.open(str(tar_path), "w") as tf:
            tf.add(str(tmp_dir / "wallet.db"), arcname="wallet.db")
            tf.add(str(tmp_dir / "exit.db"), arcname="exit.db")
            tf.add(str(tmp_dir / "manifest.json"), arcname="manifest.json")

        return tar_path

    except Exception:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        raise


def _build_manifest(wallet_path: Path, exit_path: Path) -> dict:
    """Read metadata from backed-up databases for the manifest."""
    manifest: dict = {
        "version": MANIFEST_VERSION,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

    # Wallet metadata
    w_conn = sqlite3.connect(str(wallet_path))
    try:
        subnet = w_conn.execute(
            "SELECT value FROM config WHERE key = 'ipv4_subnet'"
        ).fetchone()
        total = w_conn.execute("SELECT count(*) FROM users").fetchone()[0]
        assigned = w_conn.execute(
            "SELECT count(*) FROM users WHERE id IS NOT NULL"
        ).fetchone()[0]
        manifest["wallet"] = {
            "clients": assigned,
            "subnet": subnet[0] if subnet else "",
            "pool_total": total,
            "pool_assigned": assigned,
        }
    finally:
        w_conn.close()

    # Exit store metadata
    e_conn = sqlite3.connect(str(exit_path))
    try:
        exits = e_conn.execute("SELECT count(*) FROM exits").fetchone()[0]
        enabled_row = e_conn.execute(
            "SELECT value FROM config WHERE key = 'multihop_enabled'"
        ).fetchone()
        active_row = e_conn.execute(
            "SELECT value FROM config WHERE key = 'active_exit'"
        ).fetchone()
        manifest["exit_store"] = {
            "exits": exits,
            "enabled": enabled_row is not None and enabled_row[0] == "1",
            "active_exit": active_row[0] if active_row else "",
        }
    finally:
        e_conn.close()

    return manifest


# ── Import ────────────────────────────────────────────────────────


def restore_backup_tar(
    tar_path: Path,
    wallet_conn: sqlite3.Connection,
    exit_conn: sqlite3.Connection,
) -> dict:
    """Validate and restore databases from a backup tar.

    1. Validates tar structure (required members only)
    2. Checks manifest version
    3. Runs PRAGMA integrity_check on both databases
    4. Restores via SQLite Online Backup API into live connections

    Returns the manifest dict on success.
    Raises BackupError on any validation or integrity failure.
    """
    # Validate tar
    try:
        tf = tarfile.open(str(tar_path), "r")
    except (tarfile.TarError, OSError) as exc:
        raise BackupError(f"Invalid backup file: {exc}") from exc

    tmp_dir = Path(tempfile.mkdtemp(prefix="phantom-restore-"))

    try:
        # Validate members — strict whitelist
        member_names = {m.name for m in tf.getmembers()}
        missing = _REQUIRED_MEMBERS - member_names
        if missing:
            raise BackupError(f"Missing files in backup: {', '.join(sorted(missing))}")

        # Check for unexpected members
        unexpected = member_names - _REQUIRED_MEMBERS
        if unexpected:
            raise BackupError(
                f"Unexpected files in backup: {', '.join(sorted(unexpected))}"
            )

        # Safe extract — only known members, no path traversal
        for member in tf.getmembers():
            if member.name not in _REQUIRED_MEMBERS:
                continue
            # Block path traversal
            if member.name != Path(member.name).name:
                raise BackupError(f"Path traversal detected: {member.name}")
            tf.extract(member, path=str(tmp_dir), filter="data")

        tf.close()

        # Read and validate manifest
        manifest_path = tmp_dir / "manifest.json"
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            raise BackupError(f"Invalid manifest: {exc}") from exc

        if manifest.get("version") != MANIFEST_VERSION:
            raise BackupError(
                f"Unsupported backup version: {manifest.get('version')}"
            )

        # Integrity check on both databases
        _integrity_check(tmp_dir / "wallet.db", "wallet.db")
        _integrity_check(tmp_dir / "exit.db", "exit.db")

        # Schema validation — tables and columns must match
        _validate_schema(tmp_dir / "wallet.db", _WALLET_SCHEMA, "wallet.db")
        _validate_schema(tmp_dir / "exit.db", _EXIT_SCHEMA, "exit.db")

        # Restore — backup from file into live connections
        wallet_src = sqlite3.connect(str(tmp_dir / "wallet.db"))
        try:
            wallet_src.backup(wallet_conn)
        finally:
            wallet_src.close()

        exit_src = sqlite3.connect(str(tmp_dir / "exit.db"))
        try:
            exit_src.backup(exit_conn)
        finally:
            exit_src.close()

        return manifest

    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def _integrity_check(db_path: Path, label: str) -> None:
    """Run PRAGMA integrity_check on a database file."""
    conn = sqlite3.connect(str(db_path))
    try:
        result = conn.execute("PRAGMA integrity_check").fetchone()
        if result is None or result[0] != "ok":
            detail = result[0] if result else "no response"
            raise BackupError(f"Integrity check failed for {label}: {detail}")
    except sqlite3.DatabaseError as exc:
        raise BackupError(f"Integrity check failed for {label}: {exc}") from exc
    finally:
        conn.close()


def _validate_schema(
    db_path: Path, expected: dict[str, set[str]], label: str
) -> None:
    """Validate that a database has the expected tables and columns."""
    conn = sqlite3.connect(str(db_path))
    try:
        # Check tables exist
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        ).fetchall()
        actual_tables = {r[0] for r in rows}

        for table, expected_cols in expected.items():
            if table not in actual_tables:
                raise BackupError(
                    f"Schema mismatch in {label}: missing table '{table}'"
                )

            # Check columns exist
            col_rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
            actual_cols = {r[1] for r in col_rows}
            missing_cols = expected_cols - actual_cols
            if missing_cols:
                raise BackupError(
                    f"Schema mismatch in {label}: table '{table}' "
                    f"missing columns: {', '.join(sorted(missing_cols))}"
                )
    finally:
        conn.close()
