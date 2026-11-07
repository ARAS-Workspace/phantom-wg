"""Tests for backup export/import — SQLite Online Backup API."""

from __future__ import annotations

import json
import shutil
import sqlite3
import tarfile
import tempfile
from pathlib import Path

import pytest

from phantom_daemon.base.backup import create_backup_tar, restore_backup_tar
from phantom_daemon.base.errors import BackupError
from phantom_daemon.base.exit_store import open_exit_store
from phantom_daemon.base.wallet import create_wallet

# ── Helpers ──────────────────────────────────────────────────────


def _add_exit(store, name: str = "test-exit") -> dict:
    return store.add_exit(
        name,
        endpoint="1.2.3.4:51820",
        address="10.99.0.2/32",
        private_key_hex="a" * 64,
        public_key_hex="b" * 64,
        preshared_key_hex="c" * 64,
    )


# ── Export ────────────────────────────────────────────────────────


class TestExport:
    def test_creates_valid_tar(self, tmp_path):
        with create_wallet(str(tmp_path)) as w, \
             open_exit_store(str(tmp_path)) as es:
            tar_path = create_backup_tar(w._conn, es._conn)

        try:
            assert tar_path.exists()
            with tarfile.open(str(tar_path), "r") as tf:
                names = {m.name for m in tf.getmembers()}
            assert names == {"wallet.db", "exit.db", "manifest.json"}
        finally:
            shutil.rmtree(tar_path.parent, ignore_errors=True)

    def test_manifest_counts(self, tmp_path):
        with create_wallet(str(tmp_path)) as w, \
             open_exit_store(str(tmp_path)) as es:
            w.assign_client("alice")
            w.assign_client("bob")
            _add_exit(es, "exit-01")

            tar_path = create_backup_tar(w._conn, es._conn)

        try:
            with tarfile.open(str(tar_path), "r") as tf:
                manifest = json.load(tf.extractfile("manifest.json"))

            assert manifest["version"] == "1.0"
            assert manifest["wallet"]["clients"] == 2
            assert manifest["wallet"]["pool_assigned"] == 2
            assert manifest["wallet"]["subnet"] == "10.8.0.0/24"
            assert manifest["exit_store"]["exits"] == 1
        finally:
            shutil.rmtree(tar_path.parent, ignore_errors=True)

    def test_exported_dbs_pass_integrity(self, tmp_path):
        with create_wallet(str(tmp_path)) as w, \
             open_exit_store(str(tmp_path)) as es:
            tar_path = create_backup_tar(w._conn, es._conn)

        extract_dir = Path(tempfile.mkdtemp())
        try:
            with tarfile.open(str(tar_path), "r") as tf:
                tf.extractall(extract_dir, filter="data")

            for db_name in ("wallet.db", "exit.db"):
                conn = sqlite3.connect(str(extract_dir / db_name))
                result = conn.execute("PRAGMA integrity_check").fetchone()
                conn.close()
                assert result[0] == "ok"
        finally:
            shutil.rmtree(tar_path.parent, ignore_errors=True)
            shutil.rmtree(extract_dir, ignore_errors=True)


# ── Import ────────────────────────────────────────────────────────


# noinspection PyUnboundLocalVariable
class TestImport:
    def test_restore_replaces_state(self, tmp_path):
        """Export with 2 clients → add 3rd → import → back to 2."""
        backup_dir = tmp_path / "backup"
        backup_dir.mkdir()
        restore_dir = tmp_path / "restore"
        restore_dir.mkdir()

        # Create state: 2 clients + 1 exit
        with create_wallet(str(backup_dir)) as w, \
             open_exit_store(str(backup_dir)) as es:
            w.assign_client("alice")
            w.assign_client("bob")
            _add_exit(es, "exit-01")
            tar_path = create_backup_tar(w._conn, es._conn)

        # Create different state: 3 clients, no exits
        with create_wallet(str(restore_dir)) as w2, \
             open_exit_store(str(restore_dir)) as es2:
            w2.assign_client("charlie")
            w2.assign_client("dave")
            w2.assign_client("eve")
            assert w2.count_assigned() == 3

            # Restore from backup
            manifest = restore_backup_tar(tar_path, w2._conn, es2._conn)

            # State should match backup (2 clients, 1 exit)
            assert w2.count_assigned() == 2
            assert w2.get_client("alice") is not None
            assert w2.get_client("bob") is not None
            assert w2.get_client("charlie") is None
            assert es2.get_exit("exit-01") is not None
            assert manifest["wallet"]["clients"] == 2

        shutil.rmtree(tar_path.parent, ignore_errors=True)

    def test_invalid_tar(self, tmp_path):
        bad_file = tmp_path / "bad.tar"
        bad_file.write_bytes(b"not a tar file")

        with (
            create_wallet(str(tmp_path)) as w,
            open_exit_store(str(tmp_path)) as es,
            pytest.raises(BackupError, match="Invalid backup file"),
        ):
            restore_backup_tar(bad_file, w._conn, es._conn)

    def test_missing_db_in_tar(self, tmp_path):
        """Tar with manifest only — missing wallet.db and exit.db."""
        tar_file = tmp_path / "incomplete.tar"
        manifest_file = tmp_path / "manifest.json"
        manifest_file.write_text('{"version": "1.0"}')

        with tarfile.open(str(tar_file), "w") as tf:
            tf.add(str(manifest_file), arcname="manifest.json")

        with (
            create_wallet(str(tmp_path)) as w,
            open_exit_store(str(tmp_path)) as es,
            pytest.raises(BackupError, match="Missing files"),
        ):
            restore_backup_tar(tar_file, w._conn, es._conn)

    def test_unexpected_files_in_tar(self, tmp_path):
        """Tar with extra unexpected file."""
        tar_file = tmp_path / "extra.tar"
        manifest_file = tmp_path / "manifest.json"
        manifest_file.write_text('{"version": "1.0"}')
        extra_file = tmp_path / "evil.sh"
        extra_file.write_text("#!/bin/bash\nrm -rf /")

        db_dir = tmp_path / "dbs"
        db_dir.mkdir()
        with create_wallet(str(db_dir)), open_exit_store(str(db_dir)):
            pass

        with tarfile.open(str(tar_file), "w") as tf:
            tf.add(str(manifest_file), arcname="manifest.json")
            tf.add(str(db_dir / "wallet.db"), arcname="wallet.db")
            tf.add(str(db_dir / "exit.db"), arcname="exit.db")
            tf.add(str(extra_file), arcname="evil.sh")

        with (
            create_wallet(str(tmp_path)) as w,
            open_exit_store(str(tmp_path)) as es,
            pytest.raises(BackupError, match="Unexpected files"),
        ):
            restore_backup_tar(tar_file, w._conn, es._conn)

    def test_bad_manifest_version(self, tmp_path):
        """Tar with unsupported manifest version."""
        db_dir = tmp_path / "dbs"
        db_dir.mkdir()
        with create_wallet(str(db_dir)), open_exit_store(str(db_dir)):
            pass

        manifest_file = tmp_path / "manifest.json"
        manifest_file.write_text('{"version": "99.0"}')

        tar_file = tmp_path / "bad_ver.tar"
        with tarfile.open(str(tar_file), "w") as tf:
            tf.add(str(db_dir / "wallet.db"), arcname="wallet.db")
            tf.add(str(db_dir / "exit.db"), arcname="exit.db")
            tf.add(str(manifest_file), arcname="manifest.json")

        with (
            create_wallet(str(tmp_path)) as w,
            open_exit_store(str(tmp_path)) as es,
            pytest.raises(BackupError, match="Unsupported backup version"),
        ):
            restore_backup_tar(tar_file, w._conn, es._conn)

    def test_corrupt_db(self, tmp_path):
        """Tar with corrupt wallet.db → integrity check fails."""
        db_dir = tmp_path / "dbs"
        db_dir.mkdir()
        with create_wallet(str(db_dir)), open_exit_store(str(db_dir)):
            pass

        corrupt_path = tmp_path / "corrupt_wallet.db"
        corrupt_path.write_bytes(b"SQLite format 3\x00" + b"\xff" * 4096)

        manifest_file = tmp_path / "manifest.json"
        manifest_file.write_text('{"version": "1.0"}')

        tar_file = tmp_path / "corrupt.tar"
        with tarfile.open(str(tar_file), "w") as tf:
            tf.add(str(corrupt_path), arcname="wallet.db")
            tf.add(str(db_dir / "exit.db"), arcname="exit.db")
            tf.add(str(manifest_file), arcname="manifest.json")

        with (
            create_wallet(str(tmp_path)) as w,
            open_exit_store(str(tmp_path)) as es,
            pytest.raises(BackupError, match="Integrity check failed"),
        ):
            restore_backup_tar(tar_file, w._conn, es._conn)

    def test_schema_mismatch(self, tmp_path):
        """Tar with wallet.db that has wrong schema → schema check fails."""
        db_dir = tmp_path / "dbs"
        db_dir.mkdir()
        with open_exit_store(str(db_dir)):
            pass

        fake_wallet = db_dir / "wallet.db"
        conn = sqlite3.connect(str(fake_wallet))
        conn.execute("CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        conn.execute("CREATE TABLE wrong_table (id TEXT PRIMARY KEY)")
        conn.commit()
        conn.close()

        manifest_file = tmp_path / "manifest.json"
        manifest_file.write_text('{"version": "1.0"}')

        tar_file = tmp_path / "bad_schema.tar"
        with tarfile.open(str(tar_file), "w") as tf:
            tf.add(str(fake_wallet), arcname="wallet.db")
            tf.add(str(db_dir / "exit.db"), arcname="exit.db")
            tf.add(str(manifest_file), arcname="manifest.json")

        with (
            create_wallet(str(tmp_path)) as w,
            open_exit_store(str(tmp_path)) as es,
            pytest.raises(BackupError, match="missing table"),
        ):
            restore_backup_tar(tar_file, w._conn, es._conn)


# ── Roundtrip ─────────────────────────────────────────────────────


class TestRoundtrip:
    def test_export_import_preserves_data(self, tmp_path):
        """Full roundtrip: create state → export → fresh DB → import → verify."""
        src_dir = tmp_path / "src"
        src_dir.mkdir()
        dst_dir = tmp_path / "dst"
        dst_dir.mkdir()

        # Source: populate with data
        with create_wallet(str(src_dir)) as w, \
             open_exit_store(str(src_dir)) as es:
            alice = w.assign_client("alice")
            w.change_dns("v4", "8.8.8.8", "8.8.4.4")
            _add_exit(es, "exit-01")
            es.activate("exit-01")

            tar_path = create_backup_tar(w._conn, es._conn)

        # Destination: fresh DBs → import
        with create_wallet(str(dst_dir)) as w2, \
             open_exit_store(str(dst_dir)) as es2:
            manifest = restore_backup_tar(tar_path, w2._conn, es2._conn)

            # Verify wallet data
            restored_alice = w2.get_client("alice")
            assert restored_alice is not None
            assert restored_alice["id"] == alice["id"]
            assert restored_alice["private_key_hex"] == alice["private_key_hex"]

            dns = w2.get_dns("v4")
            assert dns == {"primary": "8.8.8.8", "secondary": "8.8.4.4"}

            # Verify exit store data — exits preserved but multihop reset to disabled
            assert es2.get_exit("exit-01") is not None
            assert es2.is_enabled() is False
            assert es2.get_active() == ""

            # Verify manifest — reflects reset state
            assert manifest["wallet"]["clients"] == 1
            assert manifest["exit_store"]["exits"] == 1
            assert manifest["exit_store"]["enabled"] is False

        shutil.rmtree(tar_path.parent, ignore_errors=True)
