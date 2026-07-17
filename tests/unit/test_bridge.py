"""
Unit tests for FirewallBridge — ufw pattern, mocked FFI.

Bridge owns DB + state. FFI calls are mocked (no .so required).
Tests verify: lifecycle, auto-persist, auto-apply, crash recovery.
"""

from unittest.mock import MagicMock, patch

import pytest

from firewall_bridge.bridge import FirewallBridge
from firewall_bridge.types import (
    AlreadyStartedError,
    NotStartedError,
    GroupNotFoundError,
)


@pytest.fixture
def mock_lib():
    lib = MagicMock()
    lib.nft_init.return_value = 0
    lib.nft_close.return_value = None
    lib.nft_add_rule.return_value = 42  # fake handle
    lib.nft_remove_rule.return_value = 0
    lib.nft_flush_table.return_value = 0
    lib.nft_list_table.return_value = None
    lib.rt_table_ensure.return_value = 0
    lib.rt_policy_add.return_value = 0
    lib.rt_policy_delete.return_value = 0
    lib.rt_route_add.return_value = 0
    lib.rt_route_delete.return_value = 0
    lib.rt_enable_ip_forward.return_value = 0
    lib.rt_flush_cache.return_value = 0
    lib.firewall_bridge_get_version.return_value = b"2.1.0"
    lib.firewall_bridge_get_last_error.return_value = b""
    lib.firewall_bridge_get_last_error_copy.return_value = 0
    lib.firewall_bridge_free_string.return_value = None
    return lib


@pytest.fixture
def bridge(mock_lib, tmp_path):
    with patch("firewall_bridge.bridge.get_lib", return_value=mock_lib):
        return FirewallBridge(str(tmp_path / "test.db"))


class TestInit:
    def test_nft_init_called(self, bridge, mock_lib):
        mock_lib.nft_init.assert_called_once()

    def test_state_is_stopped(self, bridge):
        assert bridge.get_state() == "stopped"

    def test_init_clears_applied(self, bridge):
        """Init always clears stale applied flags (crash recovery)."""
        # Internally _db.clear_applied_state() was called in __init__
        # We verify by checking no rules are applied
        assert bridge.list_firewall_rules() == []


class TestLifecycle:
    def test_start(self, bridge, mock_lib):
        bridge.start()
        assert bridge.get_state() == "started"
        mock_lib.nft_flush_table.assert_called()

    def test_stop(self, bridge):
        bridge.start()
        bridge.stop()
        assert bridge.get_state() == "stopped"

    def test_start_twice_raises(self, bridge):
        bridge.start()
        with pytest.raises(AlreadyStartedError):
            bridge.start()

    def test_stop_without_start_raises(self, bridge):
        with pytest.raises(NotStartedError):
            bridge.stop()

    def test_close(self, bridge, mock_lib):
        bridge.close()
        mock_lib.nft_close.assert_called_once()

    def test_context_manager(self, mock_lib, tmp_path):
        with patch("firewall_bridge.bridge.get_lib", return_value=mock_lib):
            with FirewallBridge(str(tmp_path / "ctx.db")) as fw:
                assert fw.get_state() == "stopped"
        mock_lib.nft_close.assert_called()


class TestRuleGroups:
    def test_create_group(self, bridge):
        g = bridge.create_group("test", "custom", 50, {"k": "v"})
        assert g.name == "test"
        assert g.metadata["k"] == "v"

    def test_delete_group(self, bridge):
        bridge.create_group("del-me")
        bridge.delete_group("del-me")
        with pytest.raises(GroupNotFoundError):
            bridge.get_group("del-me")

    def test_delete_nonexistent(self, bridge):
        with pytest.raises(GroupNotFoundError):
            bridge.delete_group("nope")

    def test_enable_disable(self, bridge):
        bridge.create_group("toggle")
        groups = bridge.list_groups()
        assert groups[0].enabled is True
        bridge.disable_group("toggle")
        assert bridge.get_group("toggle").enabled is False
        bridge.enable_group("toggle")
        assert bridge.get_group("toggle").enabled is True

    def test_list_groups(self, bridge):
        bridge.create_group("a", priority=50)
        bridge.create_group("b", priority=10)
        groups = bridge.list_groups()
        assert len(groups) == 2
        assert groups[0].name == "b"  # lower priority first


class TestFirewallRulesCRUD:
    def test_add_rule_persisted(self, bridge):
        bridge.create_group("g1")
        rid = bridge.add_firewall_rule("g1", "input", "accept", proto="tcp", dport=443)
        assert rid > 0
        rules = bridge.list_firewall_rules("g1")
        assert len(rules) == 1
        assert rules[0].chain == "input"

    def test_remove_rule(self, bridge):
        bridge.create_group("g1")
        rid = bridge.add_firewall_rule("g1", "input", "accept")
        bridge.remove_firewall_rule(rid)
        assert len(bridge.list_firewall_rules("g1")) == 0


class TestAutoApply:
    """When bridge is started, CRUD auto-applies to kernel."""

    def test_add_rule_while_started(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.start()
        _rid = bridge.add_firewall_rule("g1", "input", "accept", proto="tcp", dport=443)
        mock_lib.nft_add_rule.assert_called()
        # Rule should be marked as applied in DB
        rules = bridge.list_firewall_rules("g1")
        assert rules[0].applied is True
        assert rules[0].nft_handle == 42

    def test_add_rule_while_stopped(self, bridge, mock_lib):
        bridge.create_group("g1")
        mock_lib.nft_add_rule.reset_mock()
        bridge.add_firewall_rule("g1", "input", "accept")
        # Should NOT call kernel when stopped
        mock_lib.nft_add_rule.assert_not_called()
        rules = bridge.list_firewall_rules("g1")
        assert rules[0].applied is False

    def test_remove_rule_while_started(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.start()
        rid = bridge.add_firewall_rule("g1", "forward", "accept")
        bridge.remove_firewall_rule(rid)
        mock_lib.nft_remove_rule.assert_called()

    def test_start_applies_existing_rules(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.add_firewall_rule("g1", "forward", "drop")
        mock_lib.nft_add_rule.reset_mock()
        bridge.start()
        assert mock_lib.nft_add_rule.call_count == 2

    def test_stop_flushes_kernel(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.start()
        mock_lib.nft_flush_table.reset_mock()
        bridge.stop()
        mock_lib.nft_flush_table.assert_called()

    def test_disabled_group_not_applied(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.disable_group("g1")
        mock_lib.nft_add_rule.reset_mock()
        bridge.start()
        mock_lib.nft_add_rule.assert_not_called()

    def test_enable_group_while_started(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.disable_group("g1")
        bridge.start()
        mock_lib.nft_add_rule.reset_mock()
        bridge.enable_group("g1")
        mock_lib.nft_add_rule.assert_called_once()

    def test_disable_group_while_started(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.start()
        bridge.disable_group("g1")
        mock_lib.nft_remove_rule.assert_called()

    def test_delete_group_while_started(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.start()
        _rid = bridge.add_firewall_rule("g1", "input", "accept")
        bridge.delete_group("g1")
        mock_lib.nft_remove_rule.assert_called()


class TestRoutingRules:
    def test_add_routing_rule(self, bridge):
        bridge.create_group("g1")
        rid = bridge.add_routing_rule("g1", "policy",
                                       from_network="10.0.0.0/24",
                                       table_name="mh", priority=100)
        assert rid > 0
        rules = bridge.list_routing_rules("g1")
        assert len(rules) == 1

    def test_routing_auto_apply(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.start()
        bridge.add_routing_rule("g1", "ensure", table_name="mh", table_id=200)
        mock_lib.rt_table_ensure.assert_called()

    def test_routing_policy_apply(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.start()
        bridge.add_routing_rule("g1", "policy",
                                 from_network="10.0.0.0/24",
                                 table_name="mh", priority=100)
        mock_lib.rt_policy_add.assert_called()

    def test_routing_policy_ipv6_apply(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.start()
        bridge.add_routing_rule("g1", "policy", family=10,
                                 from_network="fd00:70:68::/120",
                                 table_name="mh6", priority=100)
        mock_lib.rt_policy_add.assert_called()
        # family=10 passed as last arg
        call_args = mock_lib.rt_policy_add.call_args
        assert call_args[0][-1] == 10

    def test_routing_route_apply(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.start()
        bridge.add_routing_rule("g1", "route",
                                 destination="default",
                                 device="wg0",
                                 table_name="mh")
        mock_lib.rt_route_add.assert_called()

    def test_routing_route_ipv6_apply(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.start()
        bridge.add_routing_rule("g1", "route", family=10,
                                 destination="default",
                                 device="wg_exit",
                                 table_name="mh6")
        mock_lib.rt_route_add.assert_called()
        call_args = mock_lib.rt_route_add.call_args
        assert call_args[0][-1] == 10


class TestCrashRecovery:
    """Simulate crash: new instance with same DB recovers state."""

    def test_recovery(self, mock_lib, tmp_path):
        db_path = str(tmp_path / "recover.db")

        with patch("firewall_bridge.bridge.get_lib", return_value=mock_lib):
            fw1 = FirewallBridge(db_path)
            fw1.create_group("vpn")
            fw1.add_firewall_rule("vpn", "input", "accept", proto="tcp", dport=443)
            fw1.add_routing_rule("vpn", "policy",
                                 from_network="10.0.0.0/24", table_name="mh",
                                 priority=100)
            fw1.start()
            # Simulate crash — no close()

        mock_lib.nft_add_rule.reset_mock()
        mock_lib.rt_policy_add.reset_mock()
        mock_lib.rt_policy_delete.reset_mock()

        with patch("firewall_bridge.bridge.get_lib", return_value=mock_lib):
            fw2 = FirewallBridge(db_path)
            # Rules still in DB, applied flags cleared by init
            rules = fw2.list_firewall_rules("vpn")
            assert len(rules) == 1
            assert rules[0].applied is False  # cleared by init

            # start() should flush stale routing then re-apply
            fw2.start()
            mock_lib.nft_add_rule.assert_called_once()
            # Stale routing flushed (best-effort delete) then re-added
            mock_lib.rt_policy_delete.assert_called_once()
            mock_lib.rt_policy_add.assert_called_once()
            rules = fw2.list_firewall_rules("vpn")
            assert rules[0].applied is True


class TestUtility:
    def test_enable_ip_forward(self, bridge, mock_lib):
        bridge.enable_ip_forward()
        mock_lib.rt_enable_ip_forward.assert_called_once()

    def test_flush_cache(self, bridge, mock_lib):
        bridge.flush_cache()
        mock_lib.rt_flush_cache.assert_called_once()

    def test_flush_table(self, bridge, mock_lib):
        bridge.flush_table()
        mock_lib.nft_flush_table.assert_called()
