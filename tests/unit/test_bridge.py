"""
Unit tests for FirewallBridge — ufw pattern, mocked FFI.

Bridge owns DB + state. FFI calls are mocked (no .so required).
Tests verify: lifecycle, auto-persist, auto-apply, crash recovery.
"""

from unittest.mock import MagicMock, patch

import pytest

from firewall_bridge.bridge import FirewallBridge
from firewall_bridge.presets import apply_preset
from firewall_bridge.types import (
    AlreadyStartedError,
    NotStartedError,
    GroupExistsError,
    GroupNotFoundError,
    InvalidParamError,
    NetlinkError,
    NftablesError,
)


@pytest.fixture
def mock_lib():
    lib = MagicMock()
    lib.nft_init.return_value = 0
    lib.nft_close.return_value = None
    lib.nft_add_rule.return_value = 42  # fake handle

    def replace_rules(rules, count, handles):
        for i in range(count):
            handles[i] = 42 + i
        return 0
    lib.nft_replace_rules.side_effect = replace_rules
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
        b = FirewallBridge(str(tmp_path / "test.db"))
    yield b
    b.close()


@pytest.fixture
def last_error():
    """The text check_result reads for a refused call."""
    with patch("firewall_bridge._ffi.get_last_error", return_value="refused"):
        yield


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
        mock_lib.nft_replace_rules.assert_called_once()

    def test_stop(self, bridge):
        bridge.start()
        bridge.stop()
        assert bridge.get_state() == "stopped"

    def test_start_writes_the_table_before_it_flushes(self, bridge, mock_lib):
        mock_lib.reset_mock()
        bridge.start()
        calls = [c[0] for c in mock_lib.method_calls]
        assert calls == ["nft_init", "nft_replace_rules"]

    def test_start_raises_when_the_table_cannot_be_written(self, bridge, mock_lib,
                                                          last_error):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        mock_lib.reset_mock()
        mock_lib.nft_init.return_value = -3
        with pytest.raises(NftablesError):
            bridge.start()
        assert bridge.get_state() == "stopped"
        assert [c[0] for c in mock_lib.method_calls] == ["nft_init"]

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

    def test_create_group_twice(self, bridge):
        bridge.create_group("g1", priority=10)
        with pytest.raises(GroupExistsError):
            bridge.create_group("g1", priority=20)
        assert [(g.name, g.priority) for g in bridge.list_groups()] == [("g1", 10)]

    def test_apply_preset_over_a_name_taken(self, bridge):
        bridge.create_group("g1")
        rule_id = bridge.add_firewall_rule("g1", "input", "drop")
        with pytest.raises(GroupExistsError):
            apply_preset(bridge, {"name": "g1", "rules": [{"chain": "input", "action": "accept"}]})
        assert [r.id for r in bridge.list_firewall_rules("g1")] == [rule_id]

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
        mock_lib.nft_add_rule.assert_not_called()
        assert mock_lib.nft_replace_rules.call_args[0][1] == 1
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
        gone = bridge.add_firewall_rule("g1", "forward", "accept")
        kept = bridge.add_firewall_rule("g1", "input", "drop")
        calls = mock_lib.nft_replace_rules.call_count
        bridge.remove_firewall_rule(gone)
        assert mock_lib.nft_replace_rules.call_count == calls + 1
        rules, count, _ = mock_lib.nft_replace_rules.call_args.args
        assert [(rules[i].chain, rules[i].action) for i in range(count)] == [(b"input", b"drop")]
        mock_lib.nft_remove_rule.assert_not_called()
        assert [(r.id, r.applied, r.nft_handle) for r in bridge.list_firewall_rules()] == [
            (kept, True, 42)]

    @pytest.mark.parametrize("disabled", [False, True])
    def test_remove_rule_not_applied_runs_no_nft(self, bridge, mock_lib, disabled):
        bridge.create_group("g1")
        rid = bridge.add_firewall_rule("g1", "input", "accept")
        if disabled:
            bridge.disable_group("g1")
            bridge.start()
        mock_lib.reset_mock()
        bridge.remove_firewall_rule(rid)
        mock_lib.nft_replace_rules.assert_not_called()
        mock_lib.nft_remove_rule.assert_not_called()
        assert bridge.list_firewall_rules() == []

    def test_start_applies_existing_rules(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.add_firewall_rule("g1", "forward", "drop")
        mock_lib.nft_add_rule.reset_mock()
        bridge.start()
        mock_lib.nft_add_rule.assert_not_called()
        rules, count, _ = mock_lib.nft_replace_rules.call_args[0]
        assert [(rules[i].chain, rules[i].action) for i in range(count)] == [
            (b"input", b"accept"), (b"forward", b"drop")]
        assert [r.nft_handle for r in bridge.list_firewall_rules()] == [42, 43]

    def test_stop_replaces_the_table_with_no_rules(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.start()
        mock_lib.reset_mock()
        bridge.stop()
        assert mock_lib.nft_replace_rules.call_args_list == [((None, 0, None),)]
        mock_lib.nft_flush_table.assert_not_called()

    def test_stop_refused_by_nft_still_stops(self, bridge, mock_lib, last_error):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.start()
        mock_lib.nft_replace_rules.side_effect = lambda rules, count, handles: -3
        bridge.stop()
        assert bridge.get_state() == "stopped"
        assert not any(r.applied for r in bridge.list_firewall_rules())

    def test_disabled_group_not_applied(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.disable_group("g1")
        mock_lib.nft_add_rule.reset_mock()
        bridge.start()
        mock_lib.nft_add_rule.assert_not_called()
        assert mock_lib.nft_replace_rules.call_args[0][1] == 0

    def test_enable_group_while_started(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.disable_group("g1")
        bridge.start()
        mock_lib.reset_mock()
        bridge.enable_group("g1")
        mock_lib.nft_add_rule.assert_not_called()
        assert mock_lib.nft_replace_rules.call_args[0][1] == 1

    def test_enable_group_already_enabled_leaves_kernel_and_db(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.start()
        mock_lib.reset_mock()
        bridge.enable_group("g1")
        assert mock_lib.method_calls == []
        assert bridge.list_firewall_rules()[0].nft_handle == 42

    def test_enable_group_unknown_raises(self, bridge):
        with pytest.raises(GroupNotFoundError):
            bridge.enable_group("nope")

    def test_disable_group_while_started(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.start()
        bridge.disable_group("g1")
        assert mock_lib.nft_replace_rules.call_args.args[1] == 0
        mock_lib.nft_remove_rule.assert_not_called()
        assert [(r.applied, r.nft_handle) for r in bridge.list_firewall_rules()] == [(False, 0)]

    def test_delete_group_while_started(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.start()
        _rid = bridge.add_firewall_rule("g1", "input", "accept")
        bridge.delete_group("g1")
        assert mock_lib.nft_replace_rules.call_args.args[1] == 0
        mock_lib.nft_remove_rule.assert_not_called()
        assert bridge.list_firewall_rules() == []

    def test_disable_group_rebuilds_the_others_in_one_run(self, bridge, mock_lib):
        bridge.create_group("a", priority=10)
        bridge.create_group("b", priority=20)
        bridge.add_firewall_rule("a", "input", "accept")
        kept = bridge.add_firewall_rule("b", "input", "drop")
        bridge.start()
        calls = mock_lib.nft_replace_rules.call_count
        bridge.disable_group("a")
        assert mock_lib.nft_replace_rules.call_count == calls + 1
        assert mock_lib.nft_replace_rules.call_args.args[1] == 1
        assert [(r.id, r.applied, r.nft_handle) for r in bridge.list_firewall_rules("b")] == [
            (kept, True, 42)]

    def test_disable_group_already_disabled_leaves_the_kernel(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.disable_group("g1")
        bridge.start()
        calls = mock_lib.nft_replace_rules.call_count
        bridge.disable_group("g1")
        bridge.delete_group("g1")
        assert mock_lib.nft_replace_rules.call_count == calls

    def test_a_group_with_no_applied_rule_leaves_the_table(self, bridge, mock_lib):
        bridge.create_group("rules")
        bridge.add_firewall_rule("rules", "input", "accept")
        bridge.create_group("routing")
        bridge.add_routing_rule("routing", "policy", from_network="10.0.0.0/24",
                                table_name="mh", priority=100)
        bridge.create_group("empty")
        bridge.start()
        mock_lib.reset_mock()
        bridge.disable_group("routing")
        bridge.delete_group("empty")
        mock_lib.nft_replace_rules.assert_not_called()
        mock_lib.rt_policy_delete.assert_called_once()
        assert not bridge.get_group("routing").enabled
        assert not any(r.applied for r in bridge.list_routing_rules())

    def test_apply_preset_while_started_rebuilds_once(self, bridge, mock_lib):
        bridge.create_group("a")
        bridge.add_firewall_rule("a", "input", "accept")
        bridge.start()
        calls = mock_lib.nft_replace_rules.call_count
        apply_preset(bridge, {"name": "p", "rules": [{"chain": "input", "action": "drop"}]})
        assert mock_lib.nft_replace_rules.call_count == calls + 1
        assert mock_lib.nft_replace_rules.call_args.args[1] == 2


class TestRefusedByKernel:
    """The kernel refuses one rule: what the call applied is removed again."""

    def test_start_undoes_what_it_applied(self, bridge, mock_lib, last_error):
        bridge.create_group("routing", priority=10)
        bridge.add_routing_rule("routing", "policy", from_network="10.0.0.0/24",
                                table_name="mh", priority=100)
        bridge.add_routing_rule("routing", "policy", from_network="10.1.0.0/24",
                                table_name="mh", priority=101)
        bridge.create_group("rules", priority=20)
        bridge.add_firewall_rule("rules", "input", "accept")
        mock_lib.reset_mock()
        mock_lib.rt_policy_add.side_effect = [0, -4]
        with pytest.raises(NetlinkError):
            bridge.start()
        assert bridge.get_state() == "stopped"
        assert [c[0] for c in mock_lib.method_calls] == [
            "nft_init", "rt_policy_delete", "rt_policy_delete",
            "nft_replace_rules", "rt_policy_add", "rt_policy_add",
            "nft_replace_rules", "rt_policy_delete",
        ]
        assert mock_lib.nft_replace_rules.call_args_list[-1] == ((None, 0, None),)
        assert not any(r.applied or r.nft_handle for r in bridge.list_firewall_rules())
        assert not any(r.applied for r in bridge.list_routing_rules())

    def test_start_refused_by_nft_empties_the_table(self, bridge, mock_lib, last_error):
        bridge.create_group("g1")
        bridge.add_routing_rule("g1", "policy", from_network="10.0.0.0/24",
                                table_name="mh", priority=100)
        bridge.add_firewall_rule("g1", "input", "masquerade")
        mock_lib.reset_mock()
        mock_lib.nft_replace_rules.side_effect = lambda rules, count, handles: -3
        with pytest.raises(NftablesError):
            bridge.start()
        assert [c[0] for c in mock_lib.method_calls] == [
            "nft_init", "rt_policy_delete", "nft_replace_rules", "nft_replace_rules",
        ]
        assert mock_lib.nft_replace_rules.call_args_list[-1] == ((None, 0, None),)
        assert bridge.get_state() == "stopped"
        assert not any(r.applied for r in bridge.list_routing_rules())

    def test_start_after_an_undone_start_tries_again(self, bridge, mock_lib, last_error):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        replace = mock_lib.nft_replace_rules.side_effect
        mock_lib.nft_replace_rules.side_effect = lambda rules, count, handles: -3
        with pytest.raises(NftablesError):
            bridge.start()
        with pytest.raises(NotStartedError):
            bridge.stop()
        mock_lib.nft_replace_rules.side_effect = replace
        bridge.start()
        assert bridge.get_state() == "started"
        assert bridge.list_firewall_rules()[0].nft_handle == 42

    def test_add_rule_while_started_stores_nothing(self, bridge, mock_lib, last_error):
        bridge.create_group("g1")
        bridge.start()
        bridge.add_firewall_rule("g1", "input", "accept")
        mock_lib.nft_replace_rules.side_effect = lambda rules, count, handles: -3
        with pytest.raises(NftablesError):
            bridge.add_firewall_rule("g1", "input", "masquerade")
        assert [(r.action, r.nft_handle) for r in bridge.list_firewall_rules()] == [("accept", 42)]

    def test_add_routing_rule_while_started_stores_nothing(self, bridge, mock_lib,
                                                           last_error):
        bridge.create_group("g1")
        bridge.start()
        mock_lib.rt_policy_add.return_value = -4
        with pytest.raises(NetlinkError):
            bridge.add_routing_rule("g1", "policy", from_network="10.0.0.0/24",
                                    table_name="mh", priority=100)
        assert bridge.list_routing_rules() == []

    @pytest.mark.parametrize("call", ["disable_group", "delete_group"])
    def test_a_refused_rebuild_leaves_the_group(self, bridge, mock_lib, last_error, call):
        bridge.create_group("g1")
        rule_id = bridge.add_firewall_rule("g1", "input", "accept")
        bridge.start()
        mock_lib.nft_replace_rules.side_effect = None
        mock_lib.nft_replace_rules.return_value = -3
        with pytest.raises(NftablesError):
            getattr(bridge, call)("g1")
        assert bridge.get_group("g1").enabled
        assert [(r.id, r.applied, r.nft_handle) for r in bridge.list_firewall_rules()] == [
            (rule_id, True, 42)]

    def test_remove_rule_refused_by_nft_keeps_it(self, bridge, mock_lib, last_error):
        bridge.create_group("g1")
        rid = bridge.add_firewall_rule("g1", "input", "accept")
        bridge.start()
        mock_lib.nft_replace_rules.side_effect = None
        mock_lib.nft_replace_rules.return_value = -3
        with pytest.raises(NftablesError):
            bridge.remove_firewall_rule(rid)
        assert [(r.id, r.applied, r.nft_handle) for r in bridge.list_firewall_rules()] == [
            (rid, True, 42)]

    def test_apply_preset_refused_by_nft_leaves_no_group(self, bridge, mock_lib, last_error):
        bridge.create_group("a")
        bridge.add_firewall_rule("a", "input", "accept")
        bridge.start()
        mock_lib.nft_replace_rules.side_effect = None
        mock_lib.nft_replace_rules.return_value = -3
        with pytest.raises(NftablesError):
            apply_preset(bridge, {"name": "p", "rules": [{"chain": "input", "action": "drop"}]})
        assert [g.name for g in bridge.list_groups()] == ["a"]
        assert [(r.applied, r.nft_handle) for r in bridge.list_firewall_rules()] == [(True, 42)]

    def test_enable_group_undoes_what_it_applied(self, bridge, mock_lib, last_error):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", "input", "accept")
        bridge.add_routing_rule("g1", "policy", from_network="10.0.0.0/24",
                                table_name="mh", priority=100)
        bridge.add_routing_rule("g1", "route", destination="default",
                                device="wg_exit", table_name="mh")
        bridge.disable_group("g1")
        bridge.start()
        mock_lib.reset_mock()
        mock_lib.rt_route_add.return_value = -4
        with pytest.raises(NetlinkError):
            bridge.enable_group("g1")
        assert bridge.get_group("g1").enabled is False
        mock_lib.nft_remove_rule.assert_called_once_with(b"input", 42)
        mock_lib.rt_policy_delete.assert_called_once()
        mock_lib.rt_route_delete.assert_not_called()
        assert not any(r.applied or r.nft_handle for r in bridge.list_firewall_rules())
        assert not any(r.applied for r in bridge.list_routing_rules())


class TestTableOrder:
    """While started, adding a rule or enabling a group rebuilds the table:
    the enabled groups' rules by group priority, in one nft call."""

    @staticmethod
    def _sent(mock_lib):
        rules, count, _ = mock_lib.nft_replace_rules.call_args[0]
        return [(rules[i].chain, rules[i].action) for i in range(count)]

    def test_a_rule_added_lands_in_its_group_place(self, bridge, mock_lib):
        bridge.create_group("late", priority=20)
        bridge.create_group("early", priority=10)
        bridge.start()
        bridge.add_firewall_rule("late", "input", "drop")
        bridge.add_firewall_rule("early", "input", "accept")
        assert self._sent(mock_lib) == [(b"input", b"accept"), (b"input", b"drop")]
        handles = {r.action: r.nft_handle for r in bridge.list_firewall_rules()}
        assert handles == {"accept": 42, "drop": 43}

    def test_an_enabled_group_lands_in_its_place(self, bridge, mock_lib):
        bridge.create_group("early", priority=10)
        bridge.add_firewall_rule("early", "input", "accept")
        bridge.disable_group("early")
        bridge.create_group("late", priority=20)
        bridge.add_firewall_rule("late", "input", "drop")
        bridge.start()
        assert self._sent(mock_lib) == [(b"input", b"drop")]
        bridge.enable_group("early")
        assert self._sent(mock_lib) == [(b"input", b"accept"), (b"input", b"drop")]

    def test_disabled_groups_stay_out(self, bridge, mock_lib):
        bridge.create_group("off", priority=10)
        bridge.add_firewall_rule("off", "input", "accept")
        bridge.disable_group("off")
        bridge.create_group("on", priority=20)
        bridge.start()
        bridge.add_firewall_rule("on", "input", "drop")
        assert self._sent(mock_lib) == [(b"input", b"drop")]
        assert [r.applied for r in bridge.list_firewall_rules()] == [False, True]


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


class TestDirectRuleFields:
    """add_firewall_rule checks its fields before the DB or the kernel."""

    def test_a_hostile_interface_reaches_neither(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.start()
        mock_lib.reset_mock()
        with pytest.raises(InvalidParamError, match="rule.in_iface"):
            bridge.add_firewall_rule("g1", "input", "accept",
                                     in_iface='wg0" accept; flush ruleset; #')
        assert mock_lib.method_calls == []
        assert bridge.list_firewall_rules() == []

    @pytest.mark.parametrize("field, value", [
        ("comment", 'a"b'),
        ("comment", "a\\b"),
        ("comment", "a\nb"),
        ("comment", "\u011f" * 65),
        ("source", "example.com"),
        ("destination", "10.0.0.0/33"),
        ("chain", "nochain"),
        ("action", "accept; flush ruleset"),
        ("state_match", "established; drop"),
        ("proto", "tcp; drop"),
        ("dport", 70000),
        ("family", 3),
        ("source", "fd00::/64"),
        ("destination", "2001:db8::1"),
        ("action", "dnat to [2001:db8::1]:443"),
    ])
    def test_each_field_is_checked(self, bridge, field, value):
        bridge.create_group("g1")
        fields = {"chain": "input", "action": "accept", field: value}
        name = {"state_match": "state"}.get(field, field)
        with pytest.raises(InvalidParamError, match=f"rule.{name}"):
            bridge.add_firewall_rule("g1", **fields)
        assert bridge.list_firewall_rules() == []

    @pytest.mark.parametrize("fields, field", [
        ({"dport": 80}, "dport"),
        ({"proto": "udp"}, "proto"),
        ({"proto": "icmp", "dport": 80}, "proto"),
    ])
    def test_a_port_and_its_protocol_go_together(self, bridge, fields, field):
        bridge.create_group("g1")
        with pytest.raises(InvalidParamError, match=f"rule.{field}"):
            bridge.add_firewall_rule("g1", "input", "accept", **fields)
        assert bridge.list_firewall_rules() == []

    def test_an_address_of_the_other_family_is_refused_for_ipv6_too(self, bridge):
        bridge.create_group("g1")
        with pytest.raises(InvalidParamError, match="not an address of family 10"):
            bridge.add_firewall_rule("g1", "input", "accept", family=10, source="10.0.0.0/8")

    @pytest.mark.parametrize("fields", [
        {"destination": "192.0.2.1"},
        {"family": 10, "source": "2001:db8::1"},
        {"source": "10.0.0.0/24"},
        {"comment": "\u011f" * 64},
        {"comment": "kural 42: wg0 \u2192 eth0"},
        {"state_match": "NEW"},
        {"action": "dnat to [2001:db8::1]:443", "family": 10, "proto": "tcp", "dport": 443},
    ])
    def test_values_taken_before_are_taken(self, bridge, fields):
        bridge.create_group("g1")
        bridge.add_firewall_rule("g1", fields.pop("chain", "input"), fields.pop("action", "accept"),
                                 **fields)
        assert len(bridge.list_firewall_rules()) == 1


class TestTableOfAGroup:
    """Policy and route rows go to the id of their group's own ensure row."""

    def test_policy_and_route_use_the_group_ensure_id(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_routing_rule("g1", "ensure", table_name="mh", table_id=200)
        bridge.add_routing_rule("g1", "policy", from_network="10.0.0.0/24",
                                table_name="mh", priority=100)
        bridge.add_routing_rule("g1", "route", destination="default",
                                device="wg_exit", table_name="mh")
        bridge.start()
        assert mock_lib.rt_policy_add.call_args[0][2] == b"200"
        assert mock_lib.rt_route_add.call_args[0][2] == b"200"
        bridge.delete_group("g1")
        assert mock_lib.rt_policy_delete.call_args[0][2] == b"200"
        assert mock_lib.rt_route_delete.call_args[0][2] == b"200"

    def test_a_route_of_an_ensured_table_is_deleted_by_any_device(self, bridge, mock_lib):
        bridge.create_group("g1")
        bridge.add_routing_rule("g1", "ensure", table_name="mh", table_id=200)
        bridge.add_routing_rule("g1", "route", destination="default",
                                device="wg_exit", table_name="mh")
        bridge.add_routing_rule("g1", "route", destination="10.9.0.0/24",
                                device="wg_exit", table_name="main")
        bridge.create_group("g2")
        bridge.add_routing_rule("g2", "route", destination="10.8.0.0/24",
                                device="wg_main", table_name="mh")
        bridge.start()
        mock_lib.rt_route_delete.reset_mock()
        bridge.stop()
        assert sorted(c.args[:3] for c in mock_lib.rt_route_delete.call_args_list) == [
            (b"10.8.0.0/24", b"wg_main", b"mh"),
            (b"10.9.0.0/24", b"wg_exit", b"main"),
            (b"default", b"", b"200"),
        ]

    def test_another_group_ensure_is_not_used(self, bridge, mock_lib):
        bridge.create_group("a")
        bridge.add_routing_rule("a", "ensure", table_name="mh", table_id=200)
        bridge.create_group("b")
        bridge.add_routing_rule("b", "policy", from_network="10.0.0.0/24",
                                table_name="mh", priority=100)
        bridge.add_routing_rule("b", "policy", from_network="10.0.0.0/24",
                                to_network="10.0.0.0/24", table_name="main", priority=99)
        bridge.start()
        assert [c[0][2] for c in mock_lib.rt_policy_add.call_args_list] == [b"mh", b"main"]


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
            assert mock_lib.nft_replace_rules.call_args[0][1] == 1
            # Stale routing flushed (best-effort delete) then re-added
            mock_lib.rt_policy_delete.assert_called_once()
            mock_lib.rt_policy_add.assert_called_once()
            rules = fw2.list_firewall_rules("vpn")
            assert rules[0].applied is True
        fw1.close()
        fw2.close()

    @staticmethod
    def _after_a_crash(mock_lib, tmp_path):
        """A bridge on the database of one that started and was not stopped,
        its group g with routing in its own table mh and in main."""
        db_path = str(tmp_path / "crash.db")
        with patch("firewall_bridge.bridge.get_lib", return_value=mock_lib):
            first = FirewallBridge(db_path)
            first.create_group("g")
            first.add_routing_rule("g", "ensure", table_name="mh", table_id=200)
            first.add_routing_rule("g", "policy", from_network="10.0.0.0/24",
                                   table_name="mh", priority=100)
            first.add_routing_rule("g", "policy", from_network="10.0.0.0/24",
                                   to_network="10.0.0.0/24", table_name="main", priority=99)
            first.add_routing_rule("g", "route", destination="default",
                                   device="wg_exit", table_name="mh")
            first.add_routing_rule("g", "route", destination="10.9.0.0/24",
                                   device="wg_exit", table_name="main")
            first.start()
            second = FirewallBridge(db_path)
        first.close()
        mock_lib.reset_mock()
        return second

    def test_delete_group_while_stopped_removes_its_routing(self, mock_lib, tmp_path):
        bridge = self._after_a_crash(mock_lib, tmp_path)
        assert not any(r.applied for r in bridge.list_routing_rules())
        bridge.delete_group("g")
        assert [c.args for c in mock_lib.rt_policy_delete.call_args_list] == [
            (b"10.0.0.0/24", b"", b"200", 100, 2),
            (b"10.0.0.0/24", b"10.0.0.0/24", b"main", 99, 2),
        ]
        assert [c.args for c in mock_lib.rt_route_delete.call_args_list] == [
            (b"default", b"", b"200", 2),
            (b"10.9.0.0/24", b"wg_exit", b"main", 2),
        ]
        mock_lib.nft_replace_rules.assert_not_called()
        assert bridge.list_groups() == []
        bridge.close()

    def test_a_refused_removal_while_stopped_is_not_raised(self, mock_lib, tmp_path):
        bridge = self._after_a_crash(mock_lib, tmp_path)
        mock_lib.rt_policy_delete.return_value = -4
        mock_lib.rt_route_delete.return_value = -4
        bridge.delete_group("g")
        assert bridge.list_groups() == []
        bridge.close()

    def test_remove_routing_rule_while_stopped_removes_it(self, mock_lib, tmp_path):
        bridge = self._after_a_crash(mock_lib, tmp_path)
        policy = next(r for r in bridge.list_routing_rules("g") if r.priority == 100)
        bridge.remove_routing_rule(policy.id)
        assert [c.args for c in mock_lib.rt_policy_delete.call_args_list] == [
            (b"10.0.0.0/24", b"", b"200", 100, 2)]
        assert policy.id not in [r.id for r in bridge.list_routing_rules()]
        bridge.close()


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
