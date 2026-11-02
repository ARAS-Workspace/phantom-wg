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

SQLite persistence layer for firewall_bridge — ufw pattern.

Four tables: config (singleton state), rule_groups, firewall_rules, routing_rules.
WAL mode for crash recovery. No domain knowledge.
"""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path
from typing import Optional

from .models import Group, FirewallRule, RoutingRule


_SCHEMA_PATH = Path(__file__).parent / "schemas" / "schema.sql"
_SCHEMA = _SCHEMA_PATH.read_text(encoding="utf-8")


def _now() -> int:
    return int(time.time())


class FirewallDB:
    """SQLite persistence — ufw pattern state store."""

    __slots__ = ("_conn",)

    def __init__(self, db_path: str) -> None:
        self._conn = sqlite3.connect(db_path)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._conn.executescript(_SCHEMA)
        self._migrate()
        self._ensure_config()

    def _migrate(self) -> None:
        """Apply schema migrations for existing databases."""
        cols = {
            row[1]
            for row in self._conn.execute("PRAGMA table_info(routing_rules)")
        }
        if "family" not in cols:
            self._conn.execute(
                "ALTER TABLE routing_rules ADD COLUMN family INTEGER NOT NULL DEFAULT 2"
            )
            self._conn.commit()

    def _ensure_config(self) -> None:
        row = self._conn.execute("SELECT id FROM config WHERE id=1").fetchone()
        if not row:
            self._conn.execute(
                "INSERT INTO config (id, state, updated_at) VALUES (1, 'stopped', ?)",
                (_now(),),
            )
            self._conn.commit()

    def close(self) -> None:
        self._conn.close()

    # ---- State ----

    def get_state(self) -> str:
        row = self._conn.execute("SELECT state FROM config WHERE id=1").fetchone()
        return row["state"] if row else "stopped"

    def set_state(self, state: str) -> None:
        self._conn.execute(
            "UPDATE config SET state=?, updated_at=? WHERE id=1",
            (state, _now()),
        )
        self._conn.commit()

    def clear_applied_state(self) -> None:
        """Clear all applied flags — crash recovery (intentional bulk update)."""
        self._conn.execute("UPDATE firewall_rules SET applied=0, nft_handle=0")
        self._conn.execute("UPDATE routing_rules SET applied=0")
        self._conn.commit()

    # ---- Rule Groups ----

    def create_group(self, name: str, group_type: str = "custom",
                     priority: int = 100, metadata: Optional[dict] = None) -> Group:
        now = _now()
        meta_json = json.dumps(metadata or {})
        try:
            self._conn.execute(
                """INSERT INTO rule_groups (name, group_type, enabled, priority, metadata,
                   created_at, updated_at) VALUES (?, ?, 1, ?, ?, ?, ?)""",
                (name, group_type, priority, meta_json, now, now),
            )
        except sqlite3.IntegrityError:
            self._conn.rollback()
            if self._conn.execute("SELECT 1 FROM rule_groups WHERE name=?", (name,)).fetchone() is None:
                raise
            from .types import GroupExistsError
            raise GroupExistsError(f"Group already exists: {name}") from None
        self._conn.commit()
        return self.get_group(name)

    def delete_group(self, name: str) -> None:
        cur = self._conn.execute("DELETE FROM rule_groups WHERE name=?", (name,))
        self._conn.commit()
        if cur.rowcount == 0:
            from .types import GroupNotFoundError
            raise GroupNotFoundError(f"Group not found: {name}")

    def get_group(self, name: str) -> Group:
        row = self._conn.execute(
            "SELECT * FROM rule_groups WHERE name=?", (name,)
        ).fetchone()
        if not row:
            from .types import GroupNotFoundError
            raise GroupNotFoundError(f"Group not found: {name}")
        return self._row_to_group(row)

    def list_groups(self) -> list[Group]:
        rows = self._conn.execute(
            "SELECT * FROM rule_groups ORDER BY priority, id"
        ).fetchall()
        return [self._row_to_group(r) for r in rows]

    def enabled_groups(self) -> list[Group]:
        rows = self._conn.execute(
            "SELECT * FROM rule_groups WHERE enabled=1 ORDER BY priority, id"
        ).fetchall()
        return [self._row_to_group(r) for r in rows]

    def enable_group(self, name: str) -> None:
        cur = self._conn.execute(
            "UPDATE rule_groups SET enabled=1, updated_at=? WHERE name=?",
            (_now(), name),
        )
        self._conn.commit()
        if cur.rowcount == 0:
            from .types import GroupNotFoundError
            raise GroupNotFoundError(f"Group not found: {name}")

    def disable_group(self, name: str) -> None:
        cur = self._conn.execute(
            "UPDATE rule_groups SET enabled=0, updated_at=? WHERE name=?",
            (_now(), name),
        )
        self._conn.commit()
        if cur.rowcount == 0:
            from .types import GroupNotFoundError
            raise GroupNotFoundError(f"Group not found: {name}")

    def is_group_enabled(self, name: str) -> bool:
        row = self._conn.execute(
            "SELECT enabled FROM rule_groups WHERE name=?", (name,)
        ).fetchone()
        return bool(row and row["enabled"])

    def _group_id(self, name: str) -> int:
        row = self._conn.execute(
            "SELECT id FROM rule_groups WHERE name=?", (name,)
        ).fetchone()
        if not row:
            from .types import GroupNotFoundError
            raise GroupNotFoundError(f"Group not found: {name}")
        return row["id"]

    @staticmethod
    def _row_to_group(row: sqlite3.Row) -> Group:
        return Group(
            id=row["id"], name=row["name"], group_type=row["group_type"],
            enabled=bool(row["enabled"]), priority=row["priority"],
            metadata=json.loads(row["metadata"]),
            created_at=row["created_at"], updated_at=row["updated_at"],
        )

    @staticmethod
    def _row_to_fw_rule(row: sqlite3.Row) -> FirewallRule:
        return FirewallRule(
            id=row["id"], group_id=row["group_id"],
            chain=row["chain"], action=row["action"], family=row["family"],
            proto=row["proto"], dport=row["dport"],
            source=row["source"], destination=row["destination"],
            in_iface=row["in_iface"], out_iface=row["out_iface"],
            state_match=row["state_match"], comment=row["comment"],
            position=row["position"],
            applied=bool(row["applied"]), nft_handle=row["nft_handle"],
            created_at=row["created_at"],
        )

    @staticmethod
    def _row_to_rt_rule(row: sqlite3.Row) -> RoutingRule:
        return RoutingRule(
            id=row["id"], group_id=row["group_id"],
            rule_type=row["rule_type"], family=row["family"],
            from_network=row["from_network"], to_network=row["to_network"],
            table_name=row["table_name"], table_id=row["table_id"],
            priority=row["priority"],
            destination=row["destination"], device=row["device"],
            applied=bool(row["applied"]), created_at=row["created_at"],
        )

    # ---- Firewall Rules ----

    def add_firewall_rule(self, group_name: str, chain: str, action: str,
                          family: int = 2, proto: str = "", dport: int = 0,
                          source: str = "", destination: str = "",
                          in_iface: str = "", out_iface: str = "",
                          state_match: str = "", comment: str = "",
                          position: int = 0) -> int:
        gid = self._group_id(group_name)
        cur = self._conn.execute(
            """INSERT INTO firewall_rules
               (group_id, chain, action, family, proto, dport, source, destination,
                in_iface, out_iface, state_match, comment, position, applied,
                nft_handle, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?)""",
            (gid, chain, action, family, proto, dport, source, destination,
             in_iface, out_iface, state_match, comment, position, _now()),
        )
        self._conn.commit()
        return cur.lastrowid

    def remove_firewall_rule(self, rule_id: int) -> FirewallRule:
        """Remove and return rule data (needed for kernel removal)."""
        row = self._conn.execute(
            "SELECT * FROM firewall_rules WHERE id=?", (rule_id,)
        ).fetchone()
        if not row:
            from .types import RuleNotFoundError
            raise RuleNotFoundError(f"Firewall rule not found: {rule_id}")
        data = self._row_to_fw_rule(row)
        self._conn.execute("DELETE FROM firewall_rules WHERE id=?", (rule_id,))
        self._conn.commit()
        return data

    def list_firewall_rules(self, group_name: Optional[str] = None) -> list[FirewallRule]:
        if group_name:
            gid = self._group_id(group_name)
            rows = self._conn.execute(
                "SELECT * FROM firewall_rules WHERE group_id=? ORDER BY position, id",
                (gid,),
            ).fetchall()
        else:
            rows = self._conn.execute(
                "SELECT * FROM firewall_rules ORDER BY group_id, position, id"
            ).fetchall()
        return [self._row_to_fw_rule(r) for r in rows]

    def firewall_rules_for_group(self, group_id: int) -> list[FirewallRule]:
        rows = self._conn.execute(
            "SELECT * FROM firewall_rules WHERE group_id=? ORDER BY position, id",
            (group_id,),
        ).fetchall()
        return [self._row_to_fw_rule(r) for r in rows]

    def update_fw_applied(self, rule_id: int, applied: bool, nft_handle: int = 0) -> None:
        self._conn.execute(
            "UPDATE firewall_rules SET applied=?, nft_handle=? WHERE id=?",
            (int(applied), nft_handle, rule_id),
        )
        self._conn.commit()

    # ---- Routing Rules ----

    def add_routing_rule(self, group_name: str, rule_type: str,
                         family: int = 2,
                         from_network: str = "", to_network: str = "",
                         table_name: str = "", table_id: int = 0,
                         priority: int = 0, destination: str = "",
                         device: str = "") -> int:
        gid = self._group_id(group_name)
        cur = self._conn.execute(
            """INSERT INTO routing_rules
               (group_id, rule_type, family, from_network, to_network, table_name, table_id,
                priority, destination, device, applied, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)""",
            (gid, rule_type, family, from_network, to_network, table_name, table_id,
             priority, destination, device, _now()),
        )
        self._conn.commit()
        return cur.lastrowid

    def remove_routing_rule(self, rule_id: int) -> RoutingRule:
        """Remove and return rule data (needed for kernel removal)."""
        row = self._conn.execute(
            "SELECT * FROM routing_rules WHERE id=?", (rule_id,)
        ).fetchone()
        if not row:
            from .types import RuleNotFoundError
            raise RuleNotFoundError(f"Routing rule not found: {rule_id}")
        data = self._row_to_rt_rule(row)
        self._conn.execute("DELETE FROM routing_rules WHERE id=?", (rule_id,))
        self._conn.commit()
        return data

    def get_routing_rule(self, rule_id: int) -> RoutingRule:
        row = self._conn.execute(
            "SELECT * FROM routing_rules WHERE id=?", (rule_id,)
        ).fetchone()
        if not row:
            from .types import RuleNotFoundError
            raise RuleNotFoundError(f"Routing rule not found: {rule_id}")
        return self._row_to_rt_rule(row)

    def list_routing_rules(self, group_name: Optional[str] = None) -> list[RoutingRule]:
        if group_name:
            gid = self._group_id(group_name)
            rows = self._conn.execute(
                "SELECT * FROM routing_rules WHERE group_id=? ORDER BY id",
                (gid,),
            ).fetchall()
        else:
            rows = self._conn.execute(
                "SELECT * FROM routing_rules ORDER BY group_id, id"
            ).fetchall()
        return [self._row_to_rt_rule(r) for r in rows]

    def routing_rules_for_group(self, group_id: int) -> list[RoutingRule]:
        rows = self._conn.execute(
            "SELECT * FROM routing_rules WHERE group_id=? ORDER BY id",
            (group_id,),
        ).fetchall()
        return [self._row_to_rt_rule(r) for r in rows]

    def ensure_table_id(self, group_id: int, table_name: str) -> Optional[int]:
        """The table id of the group's first ensure row for table_name."""
        row = self._conn.execute(
            "SELECT table_id FROM routing_rules WHERE group_id=? AND rule_type='ensure' "
            "AND table_name=? ORDER BY id LIMIT 1",
            (group_id, table_name),
        ).fetchone()
        return None if row is None else row[0]

    def update_rt_applied(self, rule_id: int, applied: bool) -> None:
        self._conn.execute(
            "UPDATE routing_rules SET applied=? WHERE id=?",
            (int(applied), rule_id),
        )
        self._conn.commit()
