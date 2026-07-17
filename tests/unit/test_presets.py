"""
Unit tests for YAML preset engine — new format (table: + rules:).
Uses mock bridge, no .so required.
"""

import builtins
import contextlib
import sys
from textwrap import dedent
from unittest.mock import MagicMock

import pytest

from firewall_bridge.models import Group
from firewall_bridge.presets import (
    apply_preset,
    remove_preset,
    enable_preset,
    disable_preset,
    list_presets,
    get_preset,
)


@pytest.fixture
def bridge():
    mock = MagicMock()
    mock.create_group.return_value = Group(name="test", enabled=True)
    mock.get_group.return_value = Group(name="test", enabled=True)
    mock.add_firewall_rule.return_value = 1
    mock.add_routing_rule.return_value = 1
    mock.delete_group.return_value = None
    mock.enable_group.return_value = None
    mock.disable_group.return_value = None
    mock.list_groups.return_value = []
    return mock


class TestApplyPresetDict:
    """apply_preset with in-memory dict (no YAML file)."""

    def test_basic_firewall_rules(self, bridge):
        spec = {
            "name": "basic",
            "priority": 100,
            "rules": [
                {"chain": "input", "action": "accept", "proto": "udp", "dport": 51820},
                {"chain": "forward", "action": "accept",
                 "in_iface": "wg0", "out_iface": "eth0"},
            ]
        }
        apply_preset(bridge, spec)

        bridge.create_group.assert_called_once_with("basic", "custom", 100, {})
        assert bridge.add_firewall_rule.call_count == 2

    def test_table_section_ensure(self, bridge):
        spec = {
            "name": "rt-test",
            "table": [
                {"ensure": {"id": 200, "name": "mh"}},
            ],
            "rules": [],
        }
        apply_preset(bridge, spec)

        bridge.add_routing_rule.assert_called_once()
        args = bridge.add_routing_rule.call_args
        assert args[1]["rule_type"] == "ensure"
        assert args[1]["table_name"] == "mh"
        assert args[1]["table_id"] == 200

    def test_table_section_policy(self, bridge):
        spec = {
            "name": "pol-test",
            "table": [
                {"policy": {"from": "10.0.1.0/24", "table": "mh", "priority": 100}},
            ],
        }
        apply_preset(bridge, spec)

        args = bridge.add_routing_rule.call_args
        assert args[1]["rule_type"] == "policy"
        assert args[1]["from_network"] == "10.0.1.0/24"
        assert args[1]["table_name"] == "mh"
        assert args[1]["priority"] == 100

    def test_table_section_route(self, bridge):
        spec = {
            "name": "route-test",
            "table": [
                {"route": {"destination": "default", "device": "wg_exit", "table": "mh"}},
            ],
        }
        apply_preset(bridge, spec)

        args = bridge.add_routing_rule.call_args
        assert args[1]["rule_type"] == "route"
        assert args[1]["destination"] == "default"
        assert args[1]["device"] == "wg_exit"
        assert args[1]["table_name"] == "mh"

    def test_metadata_stored(self, bridge):
        spec = {
            "name": "test-meta",
            "metadata": {"description": "test desc"},
            "rules": [],
        }
        apply_preset(bridge, spec)

        args = bridge.create_group.call_args
        assert args[0][3] == {"description": "test desc"}

    def test_override_metadata(self, bridge):
        spec = {"name": "test-override", "rules": []}
        apply_preset(bridge, spec, custom_field="value")

        args = bridge.create_group.call_args
        assert args[0][3]["custom_field"] == "value"

    def test_empty_rules(self, bridge):
        spec = {"name": "empty", "rules": []}
        apply_preset(bridge, spec)

        bridge.create_group.assert_called_once()
        bridge.add_firewall_rule.assert_not_called()
        bridge.add_routing_rule.assert_not_called()

    def test_no_rules_key(self, bridge):
        spec = {"name": "minimal"}
        apply_preset(bridge, spec)

        bridge.create_group.assert_called_once()
        bridge.add_firewall_rule.assert_not_called()

    def test_returns_group(self, bridge):
        spec = {"name": "ret-test"}
        bridge.get_group.return_value = Group(name="ret-test", enabled=True)
        result = apply_preset(bridge, spec)
        assert result.name == "ret-test"

    def test_default_priority(self, bridge):
        spec = {"name": "no-priority"}
        apply_preset(bridge, spec)

        args = bridge.create_group.call_args
        assert args[0][2] == 100

    def test_default_family(self, bridge):
        spec = {
            "name": "fam-test",
            "rules": [{"chain": "input", "action": "drop"}],
        }
        apply_preset(bridge, spec)

        args = bridge.add_firewall_rule.call_args
        assert args[1]["family"] == 2

    def test_ipv6_family(self, bridge):
        spec = {
            "name": "ipv6-test",
            "rules": [{"chain": "input", "action": "drop", "family": 10}],
        }
        apply_preset(bridge, spec)

        args = bridge.add_firewall_rule.call_args
        assert args[1]["family"] == 10

    def test_state_match(self, bridge):
        spec = {
            "name": "state-test",
            "rules": [{"chain": "forward", "action": "accept",
                        "state": "established,related"}],
        }
        apply_preset(bridge, spec)

        args = bridge.add_firewall_rule.call_args
        assert args[1]["state_match"] == "established,related"


class TestApplyPresetYAML:
    """apply_preset with YAML — file (Path) and raw string."""

    def test_load_yaml_file(self, bridge, tmp_path):
        yaml_content = dedent("""\
            name: yaml-test
            priority: 50
            rules:
              - chain: input
                action: accept
                proto: tcp
                dport: 8080
        """)
        yaml_file = tmp_path / "test.yaml"
        yaml_file.write_text(yaml_content)

        apply_preset(bridge, yaml_file)
        bridge.create_group.assert_called_once()
        bridge.add_firewall_rule.assert_called_once()

    def test_yaml_with_table_section(self, bridge, tmp_path):
        yaml_content = dedent("""\
            name: table-yaml
            table:
              - ensure: {id: 200, name: mh}
              - policy: {from: 10.0.1.0/24, table: mh, priority: 100}
              - route: {destination: default, device: wg0, table: mh}
            rules:
              - chain: forward
                action: accept
        """)
        yaml_file = tmp_path / "table.yaml"
        yaml_file.write_text(yaml_content)

        apply_preset(bridge, yaml_file)
        assert bridge.add_routing_rule.call_count == 3
        assert bridge.add_firewall_rule.call_count == 1

    def test_raw_yaml_string(self, bridge):
        raw = dedent("""\
            name: raw-test
            priority: 60
            rules:
              - chain: input
                action: accept
                proto: udp
                dport: 51820
        """)
        apply_preset(bridge, raw)
        bridge.create_group.assert_called_once_with("raw-test", "custom", 60, {})
        bridge.add_firewall_rule.assert_called_once()

    def test_raw_yaml_equals_dict(self, bridge):
        import yaml

        raw = dedent("""\
            name: eq-test
            priority: 70
            table:
              - ensure: {id: 200, name: mh}
            rules:
              - chain: forward
                action: accept
                in_iface: wg0
                out_iface: eth0
        """)
        parsed = yaml.safe_load(raw)

        apply_preset(bridge, raw)
        calls_raw = bridge.method_calls.copy()
        bridge.reset_mock()

        apply_preset(bridge, parsed)
        calls_dict = bridge.method_calls.copy()

        assert calls_raw == calls_dict, "Raw YAML and dict should produce identical calls"

    def test_file_not_found(self, bridge):
        from pathlib import Path
        with pytest.raises(FileNotFoundError, match="not found"):
            apply_preset(bridge, Path("/nonexistent/preset.yaml"))


class TestPresetManagement:
    def test_remove_preset(self, bridge):
        remove_preset(bridge, "test-group")
        bridge.delete_group.assert_called_once_with("test-group")

    def test_enable_preset(self, bridge):
        enable_preset(bridge, "test-group")
        bridge.enable_group.assert_called_once_with("test-group")

    def test_disable_preset(self, bridge):
        disable_preset(bridge, "test-group")
        bridge.disable_group.assert_called_once_with("test-group")

    def test_list_presets(self, bridge):
        bridge.list_groups.return_value = [
            Group(name="a", enabled=True),
            Group(name="b", enabled=False),
        ]
        result = list_presets(bridge)
        assert len(result) == 2

    def test_get_preset(self, bridge):
        bridge.get_group.return_value = Group(name="a", enabled=True)
        result = get_preset(bridge, "a")
        assert result.name == "a"


class TestMultihopPreset:
    """Full multihop preset — validates new YAML format."""

    def test_multihop_full(self, bridge):
        spec = {
            "name": "multihop-exit",
            "priority": 80,
            "metadata": {"description": "Forward traffic between interfaces"},
            "table": [
                {"ensure": {"id": 200, "name": "mh"}},
                {"policy": {"from": "10.0.1.0/24", "table": "mh", "priority": 100}},
                {"route": {"destination": "default", "device": "wg_exit", "table": "mh"}},
            ],
            "rules": [
                {"chain": "forward", "action": "accept",
                 "in_iface": "wg_main", "out_iface": "wg_exit"},
                {"chain": "forward", "action": "accept",
                 "in_iface": "wg_exit", "out_iface": "wg_main",
                 "state": "established,related"},
                {"chain": "postrouting", "action": "masquerade",
                 "source": "10.0.1.0/24", "out_iface": "wg_exit"},
            ],
        }
        apply_preset(bridge, spec)

        # 3 routing rules from table: section
        assert bridge.add_routing_rule.call_count == 3
        rt_calls = bridge.add_routing_rule.call_args_list
        assert rt_calls[0][1]["rule_type"] == "ensure"
        assert rt_calls[1][1]["rule_type"] == "policy"
        assert rt_calls[1][1]["from_network"] == "10.0.1.0/24"
        assert rt_calls[2][1]["rule_type"] == "route"
        assert rt_calls[2][1]["destination"] == "default"

        # 3 firewall rules from rules: section
        assert bridge.add_firewall_rule.call_count == 3
        fw_calls = bridge.add_firewall_rule.call_args_list
        assert fw_calls[0][1]["in_iface"] == "wg_main"
        assert fw_calls[0][1]["out_iface"] == "wg_exit"
        assert fw_calls[1][1]["state_match"] == "established,related"
        assert fw_calls[2][1]["action"] == "masquerade"
        assert fw_calls[2][1]["source"] == "10.0.1.0/24"

    def test_multihop_v6_full(self, bridge):
        spec = {
            "name": "multihop-exit-v6",
            "priority": 80,
            "metadata": {"description": "IPv6 forward traffic between interfaces"},
            "table": [
                {"ensure": {"id": 201, "name": "mh6", "family": 10}},
                {"policy": {"from": "fd00:70:68::/120", "table": "mh6", "priority": 100, "family": 10}},
                {"route": {"destination": "default", "device": "wg_exit", "table": "mh6", "family": 10}},
            ],
            "rules": [
                {"chain": "forward", "action": "accept", "family": 10,
                 "in_iface": "wg_main", "out_iface": "wg_exit"},
                {"chain": "forward", "action": "accept", "family": 10,
                 "in_iface": "wg_exit", "out_iface": "wg_main",
                 "state": "established,related"},
                {"chain": "postrouting", "action": "masquerade", "family": 10,
                 "source": "fd00:70:68::/120", "out_iface": "wg_exit"},
            ],
        }
        apply_preset(bridge, spec)

        # 3 routing rules with family=10
        assert bridge.add_routing_rule.call_count == 3
        rt_calls = bridge.add_routing_rule.call_args_list
        assert rt_calls[0][1]["family"] == 10
        assert rt_calls[1][1]["family"] == 10
        assert rt_calls[1][1]["from_network"] == "fd00:70:68::/120"
        assert rt_calls[2][1]["family"] == 10
        assert rt_calls[2][1]["destination"] == "default"

        # 3 firewall rules with family=10
        assert bridge.add_firewall_rule.call_count == 3
        fw_calls = bridge.add_firewall_rule.call_args_list
        assert fw_calls[0][1]["family"] == 10
        assert fw_calls[1][1]["family"] == 10
        assert fw_calls[2][1]["family"] == 10

    def test_routing_family_default_ipv4(self, bridge):
        spec = {
            "name": "fam-default",
            "table": [
                {"policy": {"from": "10.0.0.0/24", "table": "t1", "priority": 100}},
            ],
        }
        apply_preset(bridge, spec)
        args = bridge.add_routing_rule.call_args
        assert args[1]["family"] == 2

    def test_routing_family_explicit_ipv6(self, bridge):
        spec = {
            "name": "fam-v6",
            "table": [
                {"route": {"destination": "default", "device": "wg0", "table": "t1", "family": 10}},
            ],
        }
        apply_preset(bridge, spec)
        args = bridge.add_routing_rule.call_args
        assert args[1]["family"] == 10


@contextlib.contextmanager
def _without_yaml():
    """Block `import yaml` and drop the cached presets module.

    Simulates a host where PyYAML is not installed, so the lazy import in
    _load_spec is the only place it would be pulled in.
    """
    real = builtins.__import__

    def _blocked(name, *a, **k):
        if name == "yaml":
            raise ImportError("No module named 'yaml'")
        return real(name, *a, **k)

    builtins.__import__ = _blocked
    saved = sys.modules.pop("yaml", None)
    sys.modules.pop("firewall_bridge.presets", None)
    try:
        yield
    finally:
        builtins.__import__ = real
        if saved is not None:
            sys.modules["yaml"] = saved
        sys.modules.pop("firewall_bridge.presets", None)


class TestYamlIsOptional:
    """PyYAML is imported lazily, only for str/Path presets.

    A consumer that resolves presets to dicts (the daemon does) must be
    able to apply them on a host without PyYAML installed — the regression
    that surfaced as ModuleNotFoundError on `import firewall_bridge`.
    """

    def test_dict_preset_needs_no_yaml(self):
        with _without_yaml():
            from firewall_bridge.presets import _load_spec
            spec = _load_spec({"name": "dictonly", "rules": []})
            assert spec["name"] == "dictonly"

    def test_yaml_string_raises_clearly_without_yaml(self):
        with _without_yaml():
            from firewall_bridge.presets import _load_spec
            with pytest.raises(ImportError, match="PyYAML is required"):
                _load_spec("name: y")
