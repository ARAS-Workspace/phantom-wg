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

Wallet database lifecycle: creation, opening, and IP pool management.
"""

from __future__ import annotations

import importlib.resources
import ipaddress
import json
import math
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from phantom_daemon.base.errors import WalletError, WalletFullError
from wireguard_go_bridge.keys import (
    derive_public_key,
    generate_preshared_key,
    generate_private_key,
)


# ── Key Generation ────────────────────────────────────────────────

def _generate_keys() -> tuple[str, str, str]:
    """Generate Curve25519 keypair + preshared key via wireguard-go-bridge."""
    priv = generate_private_key()
    pub = derive_public_key(priv)
    psk = generate_preshared_key()
    return priv, pub, psk


# ── Defaults ─────────────────────────────────────────────────────

_DEFAULT_IPV4_SUBNET = "10.8.0.0/24"
_DEFAULT_DNS_V4 = {"primary": "9.9.9.9", "secondary": "149.112.112.112"}
_DEFAULT_DNS_V6 = {"primary": "2620:fe::fe", "secondary": "2620:fe::9"}


# ── IP Validation ────────────────────────────────────────────────


def _validate_ip(address: str, family: str) -> str:
    """Validate and normalise an IP address. Raises WalletError."""
    if family == "v4":
        try:
            addr = ipaddress.IPv4Address(address)
        except ValueError:
            raise WalletError(f"Invalid IPv4 address: {address}")
        return str(addr)
    elif family == "v6":
        try:
            addr = ipaddress.IPv6Address(address)
        except ValueError:
            raise WalletError(f"Invalid IPv6 address: {address}")
        return str(addr)
    else:
        raise WalletError(f"Unknown address family: {family}")


# ── Terazi ───────────────────────────────────────────────────────

def _calculate_terazi(ipv4_subnet: str) -> tuple[str, str, int, int]:
    """Calculate matching IPv6 subnet from IPv4 subnet.

    Returns (ipv4_str, ipv6_str, capacity, host_bits).
    capacity = usable client slots (total - network - broadcast - server).
    """
    v4_net = ipaddress.ip_network(ipv4_subnet, strict=False)
    host_bits = 32 - v4_net.prefixlen
    v6_prefix = 128 - host_bits
    v6_net = ipaddress.ip_network(f"fd00:70:68::/{v6_prefix}")
    capacity = v4_net.num_addresses - 3  # network + broadcast + server
    return str(v4_net), str(v6_net), capacity, host_bits


# ── IP Pool ──────────────────────────────────────────────────────

def _populate_ip_pool(
    conn: sqlite3.Connection,
    ipv4_subnet: str,
    ipv6_subnet: str,
) -> None:
    """Pre-populate users table with all usable IP pairs (index 2..max)."""
    v4_net = ipaddress.ip_network(ipv4_subnet, strict=False)
    v6_net = ipaddress.ip_network(ipv6_subnet, strict=False)

    rows = []
    # index 0 = network, 1 = server (gateway), last = broadcast (IPv4)
    # start from index 2 up to num_addresses - 2 (skip broadcast)
    for i in range(2, v4_net.num_addresses - 1):
        v4_addr = str(v4_net[i])
        v6_addr = str(v6_net[i])
        rows.append((v4_addr, v6_addr))

    conn.executemany(
        "INSERT INTO users (ipv4_address, ipv6_address) VALUES (?, ?)",
        rows,
    )


# ── Schema ───────────────────────────────────────────────────────

def _read_schema() -> str:
    """Read schema.sql from package resources."""
    ref = importlib.resources.files("phantom_daemon.base.wallet").joinpath("schema.sql")
    return ref.read_text(encoding="utf-8")


# ── Connection ───────────────────────────────────────────────────

def _connect(db_path: Path) -> sqlite3.Connection:
    """Open an existing wallet database."""
    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA wal_autocheckpoint = 1")
    return conn


def _create_wallet(db_path: Path) -> sqlite3.Connection:
    """Create a new wallet database with schema, config defaults, and IP pool."""
    conn = sqlite3.connect(str(db_path))
    try:
        # Apply schema
        schema = _read_schema()
        conn.executescript(schema)
        conn.execute("PRAGMA wal_autocheckpoint = 1")

        # Config defaults
        ipv4_str, ipv6_str, _capacity, _host_bits = _calculate_terazi(
            _DEFAULT_IPV4_SUBNET
        )
        config_rows = [
            ("ipv4_subnet", ipv4_str),
            ("ipv6_subnet", ipv6_str),
            ("dns_v4", json.dumps(_DEFAULT_DNS_V4)),
            ("dns_v6", json.dumps(_DEFAULT_DNS_V6)),
        ]
        conn.executemany(
            "INSERT INTO config (key, value) VALUES (?, ?)", config_rows
        )

        # IP pool
        _populate_ip_pool(conn, ipv4_str, ipv6_str)

        conn.commit()
    except Exception:
        conn.close()
        raise
    return conn


# ── Wallet ───────────────────────────────────────────────────────

class Wallet:
    """Minimal wallet database handle with config and user queries."""

    __slots__ = ("_conn", "_db_path")

    def __init__(self, conn: sqlite3.Connection, db_path: Path) -> None:
        self._conn = conn
        self._db_path = db_path

    def get_config(self, key: str) -> Optional[str]:
        """Get a single config value by key."""
        row = self._conn.execute(
            "SELECT value FROM config WHERE key = ?", (key,)
        ).fetchone()
        return row[0] if row else None

    def get_all_config(self) -> dict[str, str]:
        """Get all config values as a dictionary."""
        rows = self._conn.execute("SELECT key, value FROM config").fetchall()
        return dict(rows)

    def count_users(self) -> int:
        """Count total IP pool slots."""
        row = self._conn.execute("SELECT count(*) FROM users").fetchone()
        return row[0]

    def count_assigned(self) -> int:
        """Count assigned (non-free) IP pool slots."""
        row = self._conn.execute(
            "SELECT count(*) FROM users WHERE id IS NOT NULL"
        ).fetchone()
        return row[0]

    def count_free(self) -> int:
        """Count free (unassigned) IP pool slots."""
        row = self._conn.execute(
            "SELECT count(*) FROM users WHERE id IS NULL"
        ).fetchone()
        return row[0]

    # ── Client CRUD ───────────────────────────────────────────────

    def assign_client(self, name: str) -> dict:
        """Assign the first free IP slot to a new client.

        Returns dict with all client fields.
        Raises WalletError on duplicate name, WalletFullError if pool exhausted.
        """
        # Duplicate check
        existing = self._conn.execute(
            "SELECT 1 FROM users WHERE name = ?", (name,)
        ).fetchone()
        if existing:
            raise WalletError(f"Client name already exists: {name}")

        # Find first free slot
        row = self._conn.execute(
            "SELECT ipv4_address, ipv6_address FROM users "
            "WHERE id IS NULL ORDER BY rowid LIMIT 1"
        ).fetchone()
        if not row:
            raise WalletFullError("IP pool is exhausted, no free slots available")

        ipv4, ipv6 = row
        client_id = uuid.uuid4().hex
        private_key, public_key, preshared_key = _generate_keys()
        now = datetime.now(timezone.utc).isoformat()

        self._conn.execute(
            "UPDATE users SET id=?, name=?, private_key_hex=?, public_key_hex=?, "
            "preshared_key_hex=?, created_at=?, updated_at=? "
            "WHERE ipv4_address=?",
            (client_id, name, private_key, public_key, preshared_key, now, now, ipv4),
        )

        self._conn.commit()

        return {
            "ipv4_address": ipv4,
            "ipv6_address": ipv6,
            "id": client_id,
            "name": name,
            "private_key_hex": private_key,
            "public_key_hex": public_key,
            "preshared_key_hex": preshared_key,
            "created_at": now,
            "updated_at": now,
        }

    def revoke_client(self, name: str) -> None:
        """Revoke a client assignment, freeing the IP slot.

        Raises WalletError if client not found.
        """
        row = self._conn.execute(
            "SELECT ipv4_address FROM users WHERE name = ?", (name,)
        ).fetchone()
        if not row:
            raise WalletError(f"Client not found: {name}")

        ipv4 = row[0]

        self._conn.execute(
            "UPDATE users SET id=NULL, name=NULL, private_key_hex=NULL, "
            "public_key_hex=NULL, preshared_key_hex=NULL, "
            "created_at=NULL, updated_at=NULL "
            "WHERE ipv4_address=?",
            (ipv4,),
        )

        self._conn.commit()

    @staticmethod
    def _row_to_client(row) -> dict:
        return {
            "ipv4_address": row[0],
            "ipv6_address": row[1],
            "id": row[2],
            "name": row[3],
            "private_key_hex": row[4],
            "public_key_hex": row[5],
            "preshared_key_hex": row[6],
            "created_at": row[7],
            "updated_at": row[8],
        }

    _CLIENT_COLUMNS = (
        "ipv4_address, ipv6_address, id, name, "
        "private_key_hex, public_key_hex, preshared_key_hex, "
        "created_at, updated_at"
    )

    def get_client(self, name: str) -> Optional[dict]:
        """Get client by name, or None if not found."""
        row = self._conn.execute(
            f"SELECT {self._CLIENT_COLUMNS} FROM users WHERE name = ?",
            (name,),
        ).fetchone()
        if not row:
            return None
        return self._row_to_client(row)

    def list_clients(self) -> list[dict]:
        """List all assigned clients ordered by rowid."""
        rows = self._conn.execute(
            f"SELECT {self._CLIENT_COLUMNS} FROM users WHERE id IS NOT NULL ORDER BY rowid"
        ).fetchall()
        return [self._row_to_client(r) for r in rows]

    def list_clients_paginated(
        self,
        page: int = 1,
        limit: int = 25,
        search: str | None = None,
        order: str = "desc",
    ) -> dict:
        """Paginated client list with optional name search and ordering.

        Returns dict with: clients, total, page, limit, pages, order.
        order is normalised to 'asc' or 'desc'.
        """
        safe_order = "ASC" if order.upper() == "ASC" else "DESC"
        offset = (page - 1) * limit

        where = "id IS NOT NULL"
        params: list = []
        if search:
            where += " AND name LIKE ?"
            params.append(f"%{search}%")

        total: int = self._conn.execute(
            f"SELECT COUNT(*) FROM users WHERE {where}", params
        ).fetchone()[0]

        rows = self._conn.execute(
            f"SELECT {self._CLIENT_COLUMNS} FROM users "
            f"WHERE {where} ORDER BY rowid {safe_order} LIMIT ? OFFSET ?",
            [*params, limit, offset],
        ).fetchall()

        pages = math.ceil(total / limit) if total > 0 else 1
        return {
            "clients": [self._row_to_client(r) for r in rows],
            "total": total,
            "page": page,
            "limit": limit,
            "pages": pages,
            "order": safe_order.lower(),
        }

    # ── DNS ────────────────────────────────────────────────────

    def get_dns(self, family: str) -> dict:
        """Get DNS config for the given address family ('v4' or 'v6').

        Returns dict with 'primary' and 'secondary' keys.
        Raises WalletError on unknown family.
        """
        key = f"dns_{family}"
        raw = self.get_config(key)
        if raw is None:
            raise WalletError(f"Unknown DNS family: {family}")
        return json.loads(raw)

    def change_dns(self, family: str, primary: str, secondary: str) -> None:
        """Change DNS servers for the given address family.

        Validates addresses, skips if unchanged (no-op), audits on change.
        """
        key = f"dns_{family}"
        old_raw = self.get_config(key)
        if old_raw is None:
            raise WalletError(f"Unknown DNS family: {family}")

        primary = _validate_ip(primary, family)
        secondary = _validate_ip(secondary, family)

        old = json.loads(old_raw)
        new = {"primary": primary, "secondary": secondary}

        if old == new:
            return  # no-op

        self._conn.execute(
            "UPDATE config SET value=? WHERE key=?",
            (json.dumps(new), key),
        )
        self._conn.commit()

    # ── Subnet Change ───────────────────────────────────────────

    def change_cidr(self, new_prefix: int) -> None:
        """Change the CIDR prefix length, re-creating the IP pool.

        Base network address is preserved from current config.
        Assigned clients are preserved and re-slotted into the new pool.
        Raises WalletError if the new prefix cannot hold existing clients.
        """
        current_v4 = self.get_config("ipv4_subnet")
        base = current_v4.split("/")[0]
        new_v4, new_v6, new_capacity, _ = _calculate_terazi(f"{base}/{new_prefix}")

        if current_v4 == new_v4:
            return  # no-op

        assigned_count = self.count_assigned()
        if assigned_count > new_capacity:
            raise WalletError(
                f"/{new_prefix} has {new_capacity} slots "
                f"but {assigned_count} clients are assigned"
            )

        # Backup assigned clients (IP-independent data, ordered by rowid)
        backups = self._conn.execute(
            "SELECT id, name, private_key_hex, public_key_hex, "
            "preshared_key_hex, created_at, updated_at "
            "FROM users WHERE id IS NOT NULL ORDER BY rowid"
        ).fetchall()

        # Rebuild pool (intentional full clear before re-populate)
        # noinspection SqlWithoutWhere
        self._conn.execute("DELETE FROM users")  # noqa: S608
        _populate_ip_pool(self._conn, new_v4, new_v6)

        # Restore clients into first free slots
        for backup in backups:
            slot = self._conn.execute(
                "SELECT ipv4_address FROM users "
                "WHERE id IS NULL ORDER BY rowid LIMIT 1"
            ).fetchone()
            self._conn.execute(
                "UPDATE users SET id=?, name=?, private_key_hex=?, "
                "public_key_hex=?, preshared_key_hex=?, created_at=?, updated_at=? "
                "WHERE ipv4_address=?",
                (*backup, slot[0]),
            )

        # Update config
        self._conn.execute(
            "UPDATE config SET value=? WHERE key='ipv4_subnet'", (new_v4,)
        )
        self._conn.execute(
            "UPDATE config SET value=? WHERE key='ipv6_subnet'", (new_v6,)
        )

        self._conn.commit()

    # ── Pool Validation ───────────────────────────────────────────

    def validate_pool(self) -> list[str]:
        """Validate IP pool integrity. Returns list of errors (empty = valid)."""
        errors: list[str] = []

        rows = self._conn.execute(
            "SELECT ipv4_address, ipv6_address FROM users ORDER BY rowid"
        ).fetchall()

        if not rows:
            errors.append("Pool is empty")
            return errors

        # Expected capacity from config
        v4_subnet = self.get_config("ipv4_subnet")
        v6_subnet = self.get_config("ipv6_subnet")
        _, _, expected_capacity, _ = _calculate_terazi(v4_subnet)
        v4_net = ipaddress.ip_network(v4_subnet, strict=False)
        v6_net = ipaddress.ip_network(v6_subnet, strict=False)

        # Check row count
        if len(rows) != expected_capacity:
            errors.append(
                f"Row count {len(rows)} != expected capacity {expected_capacity}"
            )

        prev_v4 = None
        for i, (v4_str, v6_str) in enumerate(rows):
            # IPv4 format
            try:
                v4_addr = ipaddress.ip_address(v4_str)
            except ValueError:
                errors.append(f"Row {i}: invalid IPv4 '{v4_str}'")
                continue

            # IPv6 format
            try:
                v6_addr = ipaddress.ip_address(v6_str)
            except ValueError:
                errors.append(f"Row {i}: invalid IPv6 '{v6_str}'")
                continue

            # Sequential IPv4
            if prev_v4 is not None and int(v4_addr) != int(prev_v4) + 1:
                errors.append(
                    f"Row {i}: IPv4 gap {prev_v4} -> {v4_addr}"
                )
            prev_v4 = v4_addr

            # Terazi index match: v4 and v6 should have the same offset
            v4_index = int(v4_addr) - int(v4_net.network_address)
            v6_index = int(v6_addr) - int(v6_net.network_address)
            if v4_index != v6_index:
                errors.append(
                    f"Row {i}: terazi mismatch v4_index={v4_index} v6_index={v6_index}"
                )

        return errors

    def close(self) -> None:
        """Close the database connection."""
        self._conn.close()

    def __enter__(self) -> Wallet:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


# ── Public entry point ───────────────────────────────────────────

def open_wallet(db_dir: str, db_name: str = "wallet.db") -> Wallet:
    """Open or create the wallet database.

    If the database file exists → open.
    If it does not exist → create with schema + defaults + IP pool.
    """
    db_dir_path = Path(db_dir)
    if not db_dir_path.is_dir():
        raise WalletError(f"Database directory does not exist: {db_dir}")

    db_path = db_dir_path / db_name

    if db_path.exists():
        conn = _connect(db_path)
    else:
        conn = _create_wallet(db_path)

    return Wallet(conn, db_path)
