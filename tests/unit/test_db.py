"""
Unit tests for FirewallDB — pure Python SQLite, no .so required.
"""

import sqlite3

import pytest

from firewall_bridge.db import FirewallDB
from firewall_bridge.types import GroupExistsError, GroupNotFoundError, RuleNotFoundError


@pytest.fixture
def db(tmp_path):
    d = FirewallDB(str(tmp_path / "test.db"))
    yield d
    d.close()


class TestSchema:
    def test_tables_created(self, db):
        tables = db._conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ).fetchall()
        names = [t["name"] for t in tables]
        assert "config" in names
        assert "rule_groups" in names
        assert "firewall_rules" in names
        assert "routing_rules" in names

    def test_wal_mode(self, db):
        mode = db._conn.execute("PRAGMA journal_mode").fetchone()[0]
        assert mode == "wal"

    def test_foreign_keys_on(self, db):
        fk = db._conn.execute("PRAGMA foreign_keys").fetchone()[0]
        assert fk == 1

    def test_config_singleton(self, db):
        rows = db._conn.execute("SELECT * FROM config").fetchall()
        assert len(rows) == 1
        assert rows[0]["id"] == 1
        assert rows[0]["state"] == "stopped"


class TestState:
    def test_default_state(self, db):
        assert db.get_state() == "stopped"

    def test_set_state(self, db):
        db.set_state("started")
        assert db.get_state() == "started"

    def test_clear_applied_state(self, db):
        db.create_group("g1")
        rid = db.add_firewall_rule("g1", "input", "accept")
        db.update_fw_applied(rid, True, 42)
        rt_id = db.add_routing_rule("g1", "policy", from_network="10.0.0.0/24")
        db.update_rt_applied(rt_id, True)

        db.clear_applied_state()

        fw = db._conn.execute("SELECT applied, nft_handle FROM firewall_rules WHERE id=?", (rid,)).fetchone()
        assert fw["applied"] == 0
        assert fw["nft_handle"] == 0
        rt = db._conn.execute("SELECT applied FROM routing_rules WHERE id=?", (rt_id,)).fetchone()
        assert rt["applied"] == 0


class TestGroups:
    def test_create_group(self, db):
        g = db.create_group("test", "custom", 50, {"key": "val"})
        assert g.name == "test"
        assert g.group_type == "custom"
        assert g.priority == 50
        assert g.enabled is True
        assert g.metadata["key"] == "val"

    def test_create_default(self, db):
        g = db.create_group("default-test")
        assert g.group_type == "custom"
        assert g.priority == 100
        assert g.metadata == {}

    def test_get_group(self, db):
        db.create_group("g1")
        g = db.get_group("g1")
        assert g.name == "g1"

    def test_get_nonexistent(self, db):
        with pytest.raises(GroupNotFoundError):
            db.get_group("nope")

    def test_delete_group(self, db):
        db.create_group("del-me")
        db.delete_group("del-me")
        with pytest.raises(GroupNotFoundError):
            db.get_group("del-me")

    def test_delete_nonexistent(self, db):
        with pytest.raises(GroupNotFoundError):
            db.delete_group("nope")

    def test_delete_cascades_firewall(self, db):
        db.create_group("cascade")
        db.add_firewall_rule("cascade", "input", "accept")
        db.delete_group("cascade")
        rows = db._conn.execute("SELECT * FROM firewall_rules").fetchall()
        assert len(rows) == 0

    def test_delete_cascades_routing(self, db):
        db.create_group("cascade-rt")
        db.add_routing_rule("cascade-rt", "policy")
        db.delete_group("cascade-rt")
        rows = db._conn.execute("SELECT * FROM routing_rules").fetchall()
        assert len(rows) == 0

    def test_list_groups(self, db):
        db.create_group("a", priority=50)
        db.create_group("b", priority=10)
        groups = db.list_groups()
        assert len(groups) == 2
        assert groups[0].name == "b"  # lower priority first

    def test_enabled_groups(self, db):
        db.create_group("on")
        db.create_group("off")
        db.disable_group("off")
        enabled = db.enabled_groups()
        assert len(enabled) == 1
        assert enabled[0].name == "on"

    def test_enable_disable(self, db):
        db.create_group("toggle")
        assert db.is_group_enabled("toggle") is True
        db.disable_group("toggle")
        assert db.is_group_enabled("toggle") is False
        db.enable_group("toggle")
        assert db.is_group_enabled("toggle") is True

    def test_enable_nonexistent(self, db):
        with pytest.raises(GroupNotFoundError):
            db.enable_group("nope")

    def test_disable_nonexistent(self, db):
        with pytest.raises(GroupNotFoundError):
            db.disable_group("nope")

    def test_unique_name(self, db):
        db.create_group("unique")
        with pytest.raises(GroupExistsError, match="Group already exists: unique"):
            db.create_group("unique")
        assert [g.name for g in db.list_groups()] == ["unique"]

    def test_a_name_taken_leaves_the_file_writable(self, db, tmp_path):
        db.create_group("unique")
        with pytest.raises(GroupExistsError):
            db.create_group("unique")
        other = sqlite3.connect(str(tmp_path / "test.db"), timeout=0)
        try:
            other.execute("UPDATE rule_groups SET priority=1")
            other.commit()
        finally:
            other.close()

    def test_a_missing_name_is_not_a_name_taken(self, db):
        with pytest.raises(sqlite3.IntegrityError, match="NOT NULL"):
            db.create_group(None)


class TestFirewallRules:
    def test_add_rule(self, db):
        db.create_group("g1")
        rid = db.add_firewall_rule("g1", "input", "accept", proto="tcp", dport=443)
        assert rid > 0

    def test_add_rule_bad_group(self, db):
        with pytest.raises(GroupNotFoundError):
            db.add_firewall_rule("nope", "input", "accept")

    def test_list_rules(self, db):
        db.create_group("g1")
        db.add_firewall_rule("g1", "input", "accept")
        db.add_firewall_rule("g1", "forward", "drop")
        rules = db.list_firewall_rules("g1")
        assert len(rules) == 2

    def test_list_all_rules(self, db):
        db.create_group("g1")
        db.create_group("g2")
        db.add_firewall_rule("g1", "input", "accept")
        db.add_firewall_rule("g2", "forward", "drop")
        rules = db.list_firewall_rules()
        assert len(rules) == 2

    def test_remove_rule(self, db):
        db.create_group("g1")
        rid = db.add_firewall_rule("g1", "input", "accept")
        removed = db.remove_firewall_rule(rid)
        assert removed.chain == "input"
        assert len(db.list_firewall_rules("g1")) == 0

    def test_remove_nonexistent(self, db):
        with pytest.raises(RuleNotFoundError):
            db.remove_firewall_rule(999)

    def test_get_rule(self, db):
        db.create_group("g1")
        rid = db.add_firewall_rule("g1", "input", "accept", proto="tcp", dport=22)
        rule = db.get_firewall_rule(rid)
        assert (rule.id, rule.chain, rule.dport, rule.applied) == (rid, "input", 22, False)
        with pytest.raises(RuleNotFoundError, match="Firewall rule not found: 999"):
            db.get_firewall_rule(999)

    def test_update_applied(self, db):
        db.create_group("g1")
        rid = db.add_firewall_rule("g1", "input", "accept")
        db.update_fw_applied(rid, True, 42)
        rules = db.list_firewall_rules("g1")
        assert rules[0].applied is True
        assert rules[0].nft_handle == 42

    def test_rules_for_group(self, db):
        db.create_group("g1")
        g = db.get_group("g1")
        db.add_firewall_rule("g1", "input", "accept")
        rules = db.firewall_rules_for_group(g.id)
        assert len(rules) == 1

    def test_all_fields_persisted(self, db):
        db.create_group("g1")
        db.add_firewall_rule(
            "g1", "forward", "accept", family=2, proto="tcp", dport=80,
            source="10.0.0.0/24", destination="8.8.8.8",
            in_iface="wg0", out_iface="eth0",
            state_match="established", comment="test-rule",
        )
        r = db.list_firewall_rules("g1")[0]
        assert r.chain == "forward"
        assert r.action == "accept"
        assert r.family == 2
        assert r.proto == "tcp"
        assert r.dport == 80
        assert r.source == "10.0.0.0/24"
        assert r.destination == "8.8.8.8"
        assert r.in_iface == "wg0"
        assert r.out_iface == "eth0"
        assert r.state_match == "established"
        assert r.comment == "test-rule"


class TestRoutingRules:
    def test_add_rule(self, db):
        db.create_group("g1")
        rid = db.add_routing_rule("g1", "policy", from_network="10.0.0.0/24",
                                   table_name="mh", priority=100)
        assert rid > 0

    def test_add_rule_bad_group(self, db):
        with pytest.raises(GroupNotFoundError):
            db.add_routing_rule("nope", "policy")

    def test_ensure_table_id_is_the_groups_first(self, db):
        g1 = db.create_group("g1")
        g2 = db.create_group("g2")
        db.add_routing_rule("g2", "ensure", table_name="mh", table_id=300)
        db.add_routing_rule("g1", "policy", from_network="10.0.0.0/24", table_name="mh",
                            table_id=400, priority=100)
        db.add_routing_rule("g1", "ensure", table_name="mh", table_id=200)
        db.add_routing_rule("g1", "ensure", table_name="mh", table_id=201)
        db.add_routing_rule("g1", "ensure", table_name="other", table_id=202)
        assert db.ensure_table_id(g1.id, "mh") == 200
        assert db.ensure_table_id(g2.id, "mh") == 300
        assert db.ensure_table_id(g2.id, "other") is None

    def test_list_rules(self, db):
        db.create_group("g1")
        db.add_routing_rule("g1", "ensure", table_name="mh", table_id=200)
        db.add_routing_rule("g1", "policy", from_network="10.0.0.0/24")
        rules = db.list_routing_rules("g1")
        assert len(rules) == 2

    def test_remove_rule(self, db):
        db.create_group("g1")
        rid = db.add_routing_rule("g1", "route", destination="default", device="wg0")
        removed = db.remove_routing_rule(rid)
        assert removed.rule_type == "route"
        assert len(db.list_routing_rules("g1")) == 0

    def test_remove_nonexistent(self, db):
        with pytest.raises(RuleNotFoundError):
            db.remove_routing_rule(999)

    def test_update_applied(self, db):
        db.create_group("g1")
        rid = db.add_routing_rule("g1", "policy")
        db.update_rt_applied(rid, True)
        rules = db.list_routing_rules("g1")
        assert rules[0].applied is True

    def test_all_fields_persisted(self, db):
        db.create_group("g1")
        db.add_routing_rule(
            "g1", "policy", from_network="10.0.0.0/24", to_network="0.0.0.0/0",
            table_name="mh", table_id=200, priority=100,
            destination="default", device="wg0",
        )
        r = db.list_routing_rules("g1")[0]
        assert r.rule_type == "policy"
        assert r.family == 2
        assert r.from_network == "10.0.0.0/24"
        assert r.to_network == "0.0.0.0/0"
        assert r.table_name == "mh"
        assert r.table_id == 200
        assert r.priority == 100
        assert r.destination == "default"

    def test_family_ipv6(self, db):
        db.create_group("g1")
        db.add_routing_rule(
            "g1", "policy", family=10, from_network="fd00:70:68::/120",
            table_name="mh6", priority=100,
        )
        r = db.list_routing_rules("g1")[0]
        assert r.family == 10
        assert r.from_network == "fd00:70:68::/120"

    def test_family_default(self, db):
        db.create_group("g1")
        db.add_routing_rule("g1", "route", destination="default", device="wg0")
        r = db.list_routing_rules("g1")[0]
        assert r.family == 2
        assert r.device == "wg0"
