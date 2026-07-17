"""
Unit tests for preset schema validation.
Pure Python, no .so required.
"""

import pytest

# noinspection PyProtectedMember
from firewall_bridge.schema import validate_preset, _is_cidr
from firewall_bridge.types import PresetValidationError


# ---- CIDR validation ----

class TestCidr:
    def test_valid_ipv4(self):
        assert _is_cidr("10.0.1.0/24")
        assert _is_cidr("192.168.0.0/16")
        assert _is_cidr("0.0.0.0/0")
        assert _is_cidr("255.255.255.255/32")

    def test_valid_ipv6(self):
        assert _is_cidr("fd00::/64")
        assert _is_cidr("2001:db8::/32")

    def test_invalid(self):
        assert not _is_cidr("10.0.1.0")
        assert not _is_cidr("not-cidr")
        assert not _is_cidr("256.0.0.0/24")
        assert not _is_cidr("10.0.1.0/33")
        assert not _is_cidr("")


# ---- Valid presets ----

class TestValidPresets:
    def test_minimal(self):
        result = validate_preset({"name": "test"})
        assert result["name"] == "test"
        assert result["priority"] == 100
        assert result["type"] == "custom"
        assert result["metadata"] == {}

    def test_full_preset(self):
        spec = {
            "name": "multihop-exit",
            "priority": 80,
            "type": "vpn",
            "metadata": {"description": "test"},
            "table": [
                {"ensure": {"id": 200, "name": "mh"}},
                {"policy": {"from": "10.0.1.0/24", "table": "mh", "priority": 100}},
                {"route": {"destination": "default", "device": "wg0", "table": "mh"}},
            ],
            "rules": [
                {"chain": "forward", "action": "accept",
                 "in_iface": "wg0", "out_iface": "eth0"},
                {"chain": "postrouting", "action": "masquerade",
                 "source": "10.0.1.0/24", "out_iface": "eth0"},
            ],
        }
        result = validate_preset(spec)
        assert result["name"] == "multihop-exit"
        assert result["priority"] == 80
        assert len(result["table"]) == 3
        assert len(result["rules"]) == 2

    def test_empty_rules(self):
        result = validate_preset({"name": "empty", "rules": []})
        assert result["rules"] == []

    def test_empty_table(self):
        result = validate_preset({"name": "empty", "table": []})
        assert result["table"] == []

    def test_rule_defaults_filled(self):
        spec = {
            "name": "defaults",
            "rules": [{"chain": "input", "action": "accept"}],
        }
        result = validate_preset(spec)
        rule = result["rules"][0]
        assert rule["family"] == 2
        assert rule["proto"] == ""
        assert rule["dport"] == 0
        assert rule["source"] == ""
        assert rule["destination"] == ""
        assert rule["in_iface"] == ""
        assert rule["out_iface"] == ""
        assert rule["state"] == ""

    def test_ipv6_family(self):
        spec = {
            "name": "ipv6",
            "rules": [{"chain": "input", "action": "drop", "family": 10}],
        }
        result = validate_preset(spec)
        assert result["rules"][0]["family"] == 10

    def test_all_valid_chains(self):
        for chain in ("input", "output", "forward", "postrouting", "prerouting"):
            spec = {
                "name": f"chain-{chain}",
                "rules": [{"chain": chain, "action": "accept"}],
            }
            result = validate_preset(spec)
            assert result["rules"][0]["chain"] == chain

    def test_all_valid_actions(self):
        for action in ("accept", "drop", "reject", "masquerade"):
            spec = {
                "name": f"action-{action}",
                "rules": [{"chain": "forward", "action": action}],
            }
            result = validate_preset(spec)
            assert result["rules"][0]["action"] == action

    def test_all_valid_protos(self):
        for proto in ("", "tcp", "udp", "icmp"):
            spec = {
                "name": f"proto-{proto or 'empty'}",
                "rules": [{"chain": "input", "action": "accept", "proto": proto}],
            }
            result = validate_preset(spec)
            assert result["rules"][0]["proto"] == proto

    def test_dport_range(self):
        spec = {
            "name": "dport",
            "rules": [{"chain": "input", "action": "accept", "dport": 51820}],
        }
        result = validate_preset(spec)
        assert result["rules"][0]["dport"] == 51820

    def test_state_match(self):
        spec = {
            "name": "state",
            "rules": [{"chain": "forward", "action": "accept",
                        "state": "established,related"}],
        }
        result = validate_preset(spec)
        assert result["rules"][0]["state"] == "established,related"

    def test_policy_with_to(self):
        spec = {
            "name": "pol-to",
            "table": [
                {"policy": {"from": "10.0.1.0/24", "to": "10.0.2.0/24",
                             "table": "mh", "priority": 99}},
            ],
        }
        result = validate_preset(spec)
        assert result["table"][0]["policy"]["to"] == "10.0.2.0/24"

    def test_priority_zero(self):
        result = validate_preset({"name": "zero-pri", "priority": 0})
        assert result["priority"] == 0

    def test_priority_max(self):
        result = validate_preset({"name": "max-pri", "priority": 999})
        assert result["priority"] == 999

    def test_dport_zero(self):
        spec = {
            "name": "dport-zero",
            "rules": [{"chain": "input", "action": "accept", "dport": 0}],
        }
        result = validate_preset(spec)
        assert result["rules"][0]["dport"] == 0

    def test_dport_max(self):
        spec = {
            "name": "dport-max",
            "rules": [{"chain": "input", "action": "accept", "dport": 65535}],
        }
        result = validate_preset(spec)
        assert result["rules"][0]["dport"] == 65535

    def test_ensure_id_boundaries(self):
        spec = {
            "name": "ensure-bounds",
            "table": [{"ensure": {"id": 1, "name": "min"}}],
        }
        result = validate_preset(spec)
        assert result["table"][0]["ensure"]["id"] == 1

        spec["table"] = [{"ensure": {"id": 65535, "name": "max"}}]
        result = validate_preset(spec)
        assert result["table"][0]["ensure"]["id"] == 65535

    def test_routing_family_default(self):
        spec = {
            "name": "rt-fam-default",
            "table": [{"policy": {"from": "10.0.0.0/24", "table": "mh", "priority": 100}}],
        }
        result = validate_preset(spec)
        assert result["table"][0]["policy"]["family"] == 2

    def test_routing_family_ipv6(self):
        spec = {
            "name": "rt-fam-v6",
            "table": [
                {"ensure": {"id": 201, "name": "mh6", "family": 10}},
                {"policy": {"from": "fd00:70:68::/120", "table": "mh6", "priority": 100, "family": 10}},
                {"route": {"destination": "default", "device": "wg0", "table": "mh6", "family": 10}},
            ],
        }
        result = validate_preset(spec)
        assert result["table"][0]["ensure"]["family"] == 10
        assert result["table"][1]["policy"]["family"] == 10
        assert result["table"][2]["route"]["family"] == 10

    def test_routing_family_invalid(self):
        with pytest.raises(PresetValidationError, match="family.*must be one of"):
            validate_preset({
                "name": "bad",
                "table": [{"policy": {"from": "10.0.0.0/24", "table": "mh",
                                       "priority": 100, "family": 4}}],
            })


# ---- Missing required fields ----

class TestMissingRequired:
    def test_missing_name(self):
        with pytest.raises(PresetValidationError, match="name.*required"):
            validate_preset({"priority": 100})

    def test_missing_chain(self):
        with pytest.raises(PresetValidationError, match="chain.*required"):
            validate_preset({
                "name": "bad",
                "rules": [{"action": "accept"}],
            })

    def test_missing_action(self):
        with pytest.raises(PresetValidationError, match="action.*required"):
            validate_preset({
                "name": "bad",
                "rules": [{"chain": "input"}],
            })

    def test_missing_ensure_id(self):
        with pytest.raises(PresetValidationError, match="id.*required"):
            validate_preset({
                "name": "bad",
                "table": [{"ensure": {"name": "mh"}}],
            })

    def test_missing_ensure_name(self):
        with pytest.raises(PresetValidationError, match="name.*required"):
            validate_preset({
                "name": "bad",
                "table": [{"ensure": {"id": 200}}],
            })

    def test_missing_policy_from(self):
        with pytest.raises(PresetValidationError, match="from.*required"):
            validate_preset({
                "name": "bad",
                "table": [{"policy": {"table": "mh", "priority": 100}}],
            })

    def test_missing_policy_table(self):
        with pytest.raises(PresetValidationError, match="table.*required"):
            validate_preset({
                "name": "bad",
                "table": [{"policy": {"from": "10.0.0.0/24", "priority": 100}}],
            })

    def test_missing_policy_priority(self):
        with pytest.raises(PresetValidationError, match="priority.*required"):
            validate_preset({
                "name": "bad",
                "table": [{"policy": {"from": "10.0.0.0/24", "table": "mh"}}],
            })

    def test_missing_route_destination(self):
        with pytest.raises(PresetValidationError, match="destination.*required"):
            validate_preset({
                "name": "bad",
                "table": [{"route": {"device": "wg0", "table": "mh"}}],
            })

    def test_missing_route_device(self):
        with pytest.raises(PresetValidationError, match="device.*required"):
            validate_preset({
                "name": "bad",
                "table": [{"route": {"destination": "default", "table": "mh"}}],
            })

    def test_missing_route_table(self):
        with pytest.raises(PresetValidationError, match="table.*required"):
            validate_preset({
                "name": "bad",
                "table": [{"route": {"destination": "default", "device": "wg0"}}],
            })


# ---- Wrong types ----

class TestWrongTypes:
    def test_name_not_string(self):
        with pytest.raises(PresetValidationError, match="name.*expected str"):
            validate_preset({"name": 123})

    def test_priority_not_int(self):
        with pytest.raises(PresetValidationError, match="priority.*expected int"):
            validate_preset({"name": "bad", "priority": "high"})

    def test_metadata_not_dict(self):
        with pytest.raises(PresetValidationError, match="metadata.*expected dict"):
            validate_preset({"name": "bad", "metadata": "string"})

    def test_table_not_list(self):
        with pytest.raises(PresetValidationError, match="table.*expected list"):
            validate_preset({"name": "bad", "table": "not-list"})

    def test_rules_not_list(self):
        with pytest.raises(PresetValidationError, match="rules.*expected list"):
            validate_preset({"name": "bad", "rules": "not-list"})

    def test_ensure_id_not_int(self):
        with pytest.raises(PresetValidationError, match="id.*expected int"):
            validate_preset({
                "name": "bad",
                "table": [{"ensure": {"id": "200", "name": "mh"}}],
            })

    def test_dport_not_int(self):
        with pytest.raises(PresetValidationError, match="dport.*expected int"):
            validate_preset({
                "name": "bad",
                "rules": [{"chain": "input", "action": "accept", "dport": "80"}],
            })

    def test_family_not_int(self):
        with pytest.raises(PresetValidationError, match="family.*expected int"):
            validate_preset({
                "name": "bad",
                "rules": [{"chain": "input", "action": "accept", "family": "inet"}],
            })

    def test_preset_not_dict(self):
        with pytest.raises(PresetValidationError, match="preset.*expected dict"):
            validate_preset("not a dict")

    def test_table_entry_not_dict(self):
        with pytest.raises(PresetValidationError, match="expected dict"):
            validate_preset({
                "name": "bad",
                "table": ["not-a-dict"],
            })

    def test_rule_not_dict(self):
        with pytest.raises(PresetValidationError, match="expected dict"):
            validate_preset({
                "name": "bad",
                "rules": ["not-a-dict"],
            })


# ---- Unknown keys (typo protection) ----

class TestUnknownKeys:
    def test_preset_unknown_key(self):
        with pytest.raises(PresetValidationError, match="unknown keys.*typo"):
            validate_preset({"name": "bad", "typo": True})

    def test_rule_unknown_key(self):
        with pytest.raises(PresetValidationError, match="unknown keys.*destnation"):
            validate_preset({
                "name": "bad",
                "rules": [{"chain": "input", "action": "accept",
                            "destnation": "10.0.0.0/24"}],
            })

    def test_table_entry_unknown_key(self):
        with pytest.raises(PresetValidationError, match="unknown keys.*ensuree"):
            validate_preset({
                "name": "bad",
                "table": [{"ensuree": {"id": 200, "name": "mh"}}],
            })

    def test_ensure_unknown_key(self):
        with pytest.raises(PresetValidationError, match="unknown keys"):
            validate_preset({
                "name": "bad",
                "table": [{"ensure": {"id": 200, "name": "mh", "extra": True}}],
            })

    def test_policy_unknown_key(self):
        with pytest.raises(PresetValidationError, match="unknown keys"):
            validate_preset({
                "name": "bad",
                "table": [{"policy": {"from": "10.0.0.0/24", "table": "mh",
                                       "priority": 100, "extra": True}}],
            })

    def test_route_unknown_key(self):
        with pytest.raises(PresetValidationError, match="unknown keys"):
            validate_preset({
                "name": "bad",
                "table": [{"route": {"destination": "default", "device": "wg0",
                                      "table": "mh", "extra": True}}],
            })


# ---- Invalid enum values ----

class TestInvalidEnums:
    def test_invalid_chain(self):
        with pytest.raises(PresetValidationError, match="chain.*must be one of"):
            validate_preset({
                "name": "bad",
                "rules": [{"chain": "custom_chain", "action": "accept"}],
            })

    def test_invalid_action(self):
        with pytest.raises(PresetValidationError, match="action.*must be one of"):
            validate_preset({
                "name": "bad",
                "rules": [{"chain": "input", "action": "allow"}],
            })

    def test_dnat_action(self):
        result = validate_preset({
            "name": "dnat-test",
            "rules": [{
                "chain": "prerouting",
                "action": "dnat to 172.28.0.4:443",
                "proto": "tcp",
                "dport": 443,
            }],
        })
        assert result["rules"][0]["action"] == "dnat to 172.28.0.4:443"

    def test_invalid_family(self):
        with pytest.raises(PresetValidationError, match="family.*must be one of"):
            validate_preset({
                "name": "bad",
                "rules": [{"chain": "input", "action": "accept", "family": 4}],
            })

    def test_invalid_proto(self):
        with pytest.raises(PresetValidationError, match="proto.*must be one of"):
            validate_preset({
                "name": "bad",
                "rules": [{"chain": "input", "action": "accept", "proto": "gre"}],
            })


# ---- Range checks ----

class TestRangeChecks:
    def test_priority_too_high(self):
        with pytest.raises(PresetValidationError, match="priority.*maximum"):
            validate_preset({"name": "bad", "priority": 1000})

    def test_priority_negative(self):
        with pytest.raises(PresetValidationError, match="priority.*minimum"):
            validate_preset({"name": "bad", "priority": -1})

    def test_dport_too_high(self):
        with pytest.raises(PresetValidationError, match="dport.*maximum"):
            validate_preset({
                "name": "bad",
                "rules": [{"chain": "input", "action": "accept", "dport": 70000}],
            })

    def test_dport_negative(self):
        with pytest.raises(PresetValidationError, match="dport.*minimum"):
            validate_preset({
                "name": "bad",
                "rules": [{"chain": "input", "action": "accept", "dport": -1}],
            })

    def test_ensure_id_zero(self):
        with pytest.raises(PresetValidationError, match="id.*minimum"):
            validate_preset({
                "name": "bad",
                "table": [{"ensure": {"id": 0, "name": "mh"}}],
            })

    def test_ensure_id_too_high(self):
        with pytest.raises(PresetValidationError, match="id.*maximum"):
            validate_preset({
                "name": "bad",
                "table": [{"ensure": {"id": 99999, "name": "mh"}}],
            })

    def test_policy_priority_negative(self):
        with pytest.raises(PresetValidationError, match="priority.*minimum"):
            validate_preset({
                "name": "bad",
                "table": [{"policy": {"from": "10.0.0.0/24", "table": "mh",
                                       "priority": -1}}],
            })


# ---- CIDR format checks ----

class TestCidrFormat:
    def test_invalid_source_cidr(self):
        with pytest.raises(PresetValidationError, match="source.*CIDR"):
            validate_preset({
                "name": "bad",
                "rules": [{"chain": "input", "action": "accept",
                            "source": "not-cidr"}],
            })

    def test_invalid_destination_cidr(self):
        with pytest.raises(PresetValidationError, match="destination.*CIDR"):
            validate_preset({
                "name": "bad",
                "rules": [{"chain": "input", "action": "accept",
                            "destination": "not-cidr"}],
            })

    def test_invalid_policy_from_cidr(self):
        with pytest.raises(PresetValidationError, match="from.*CIDR"):
            validate_preset({
                "name": "bad",
                "table": [{"policy": {"from": "not-cidr", "table": "mh",
                                       "priority": 100}}],
            })

    def test_invalid_policy_to_cidr(self):
        with pytest.raises(PresetValidationError, match="to.*CIDR"):
            validate_preset({
                "name": "bad",
                "table": [{"policy": {"from": "10.0.0.0/24", "to": "bad",
                                       "table": "mh", "priority": 100}}],
            })

    def test_empty_source_is_valid(self):
        spec = {
            "name": "ok",
            "rules": [{"chain": "input", "action": "accept", "source": ""}],
        }
        result = validate_preset(spec)
        assert result["rules"][0]["source"] == ""

    def test_empty_destination_is_valid(self):
        spec = {
            "name": "ok",
            "rules": [{"chain": "input", "action": "accept", "destination": ""}],
        }
        result = validate_preset(spec)
        assert result["rules"][0]["destination"] == ""


# ---- Table entry validation ----

class TestTableEntryValidation:
    def test_empty_table_entry(self):
        with pytest.raises(PresetValidationError, match="must contain one of"):
            validate_preset({
                "name": "bad",
                "table": [{}],
            })

    def test_multiple_entry_types(self):
        with pytest.raises(PresetValidationError, match="must contain exactly one"):
            validate_preset({
                "name": "bad",
                "table": [{"ensure": {"id": 1, "name": "x"},
                            "route": {"destination": "d", "device": "d", "table": "t"}}],
            })


# ---- PresetValidationError attributes ----

class TestErrorAttributes:
    def test_error_has_field(self):
        try:
            validate_preset({"name": 123})
        except PresetValidationError as e:
            assert e.field == "preset.name"
            assert "expected str" in e.reason
            assert e.value == 123

    def test_error_message_format(self):
        try:
            validate_preset({"name": "bad", "priority": "high"})
        except PresetValidationError as e:
            assert "preset.priority" in str(e)
            assert "expected int" in str(e)
            assert "'high'" in str(e)

    def test_inherits_bridge_error(self):
        from firewall_bridge.types import BridgeError
        with pytest.raises(BridgeError):
            validate_preset({})


# ---- Injection surface ----


class TestNoCommandInjection:
    """Every field below is formatted straight into an nftables command by
    build_rule_cmd. libnftables accepts multiple ';'-separated commands per
    buffer, so a value that can close a quote or start a statement escapes
    the `inet phantom` table the whole design relies on for isolation.
    """

    @pytest.mark.parametrize("field", ["in_iface", "out_iface"])
    def test_iface_cannot_close_the_quote(self, field):
        with pytest.raises(PresetValidationError, match="interface name"):
            validate_preset({
                "name": "inj",
                "rules": [{
                    "chain": "forward", "action": "accept",
                    field: 'wg0" ; add rule inet phantom input drop ; #',
                }],
            })

    @pytest.mark.parametrize("field", ["in_iface", "out_iface"])
    def test_iface_length_capped(self, field):
        """IFNAMSIZ-1 — the kernel would not accept it either."""
        with pytest.raises(PresetValidationError, match="interface name"):
            validate_preset({
                "name": "inj",
                "rules": [{"chain": "forward", "action": "accept",
                           field: "a" * 16}],
            })

    def test_state_cannot_inject(self):
        with pytest.raises(PresetValidationError, match="comma-separated subset"):
            validate_preset({
                "name": "inj",
                "rules": [{"chain": "forward", "action": "accept",
                           "state": "established ; flush ruleset ; #"}],
            })

    def test_state_rejects_unknown_verb(self):
        with pytest.raises(PresetValidationError, match="comma-separated subset"):
            validate_preset({
                "name": "inj",
                "rules": [{"chain": "forward", "action": "accept",
                           "state": "established,bogus"}],
            })

    def test_dnat_cannot_append_a_command(self):
        """v2.1.4 relaxed action from enum to enum_prefix so 'dnat to <x>'
        would validate; anything starting with 'dnat ' then reached the
        parser, and `flush ruleset` wipes every table on the host."""
        with pytest.raises(PresetValidationError, match="dnat must be"):
            validate_preset({
                "name": "inj",
                "rules": [{"chain": "postrouting",
                           "action": "dnat to 1.2.3.4 ; flush ruleset ; #"}],
            })

    def test_dnat_target_must_be_an_ip(self):
        with pytest.raises(PresetValidationError, match="not a valid IP"):
            validate_preset({
                "name": "inj",
                "rules": [{"chain": "postrouting", "action": "dnat to evil.example.com"}],
            })

    def test_dnat_port_range(self):
        with pytest.raises(PresetValidationError, match="port out of range"):
            validate_preset({
                "name": "inj",
                "rules": [{"chain": "postrouting", "action": "dnat to 1.2.3.4:99999"}],
            })


class TestLegitimateValuesStillPass:
    """The hardening must not narrow what the shipped presets already use."""

    def test_real_interface_names(self):
        result = validate_preset({
            "name": "ok",
            "rules": [{"chain": "forward", "action": "accept",
                       "in_iface": "wg_phantom_main",
                       "out_iface": "wg_phantom_exit"}],
        })
        assert result["rules"][0]["in_iface"] == "wg_phantom_main"

    def test_ct_state_list(self):
        result = validate_preset({
            "name": "ok",
            "rules": [{"chain": "forward", "action": "accept",
                       "state": "established,related"}],
        })
        assert result["rules"][0]["state"] == "established,related"

    def test_dnat_v4_and_v6(self):
        for target in ("dnat to 172.28.0.4:443", "dnat to 10.0.0.1",
                       "dnat to [2001:db8::1]:443"):
            result = validate_preset({
                "name": "ok",
                "rules": [{"chain": "prerouting", "action": target}],
            })
            assert result["rules"][0]["action"] == target


class TestCidrIsNotDecorative:
    def test_ipv6_garbage_rejected(self):
        """The old regex was hex-digits-and-colons plus a 1-3 digit prefix."""
        assert not _is_cidr(":::::/999")
        assert not _is_cidr("fd00::/999")
        assert not _is_cidr("gggg::/64")

    def test_ipv6_still_accepted(self):
        assert _is_cidr("fd00:70:68::/118")
        assert _is_cidr("2001:db8::/32")
        assert _is_cidr("::/0")
