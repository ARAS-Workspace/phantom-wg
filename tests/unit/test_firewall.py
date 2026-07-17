"""Tests for phantom_daemon.base.services.firewall — real bridge, real wallet, no mocks."""

from __future__ import annotations

from pathlib import Path

import pytest

from phantom_daemon.base.errors import FirewallError
from phantom_daemon.base.wallet import open_wallet
from phantom_daemon.base.services.firewall.service import (
    CORE_PRESET_NAME,
    MULTIHOP_PRESET_NAME,
    MULTIHOP_V6_PRESET_NAME,
    FirewallService,
    _read_core_preset,
    _read_multihop_preset,
    _resolve_core_preset,
    resolve_multihop_preset,
    resolve_multihop_v6_preset,
    open_firewall,
)
from phantom_daemon.base.services.wireguard import WG_INTERFACE_NAME


# ── TestResolvePreset (pure — no FFI) ────────────────────────────


class TestResolvePreset:
    def test_read_core_preset(self):
        """core.yaml is loadable and has expected structure."""
        spec = _read_core_preset()
        assert spec["name"] == CORE_PRESET_NAME
        assert spec["priority"] == 50
        assert len(spec["rules"]) == 6

    def test_resolve_injects_listen_port(self, test_env):
        """rules[0] (input/udp) gets listen_port from env."""
        spec = _resolve_core_preset(test_env.env, test_env.wallet)
        assert spec["rules"][0]["dport"] == test_env.env.listen_port

    def test_resolve_injects_interface(self, test_env):
        """rules[2]/[3] (forward) get WG_INTERFACE_NAME."""
        from phantom_daemon.base.services.wireguard import WG_INTERFACE_NAME

        spec = _resolve_core_preset(test_env.env, test_env.wallet)
        assert spec["rules"][2]["in_iface"] == WG_INTERFACE_NAME
        assert spec["rules"][3]["out_iface"] == WG_INTERFACE_NAME


# ── TestResolveMultihopPreset ─────────────────────────────────────


class TestResolveMultihopPreset:
    def test_read_multihop_preset(self):
        """multihop.yaml is loadable and has expected structure."""
        spec = _read_multihop_preset()
        assert spec["name"] == MULTIHOP_PRESET_NAME
        assert spec["priority"] == 80
        assert len(spec["rules"]) == 3
        assert "table" in spec

    def test_resolve_injects_interfaces(self):
        spec = resolve_multihop_preset(
            ipv4_subnet="10.8.0.0/24",
            wg_interface="wg_main",
            wg_interface_exit="wg_exit",
        )
        # Rules check
        assert spec["rules"][0]["in_iface"] == "wg_main"
        assert spec["rules"][0]["out_iface"] == "wg_exit"
        assert spec["rules"][1]["in_iface"] == "wg_exit"
        assert spec["rules"][1]["out_iface"] == "wg_main"
        assert spec["rules"][2]["out_iface"] == "wg_exit"
        assert spec["rules"][2]["source"] == "10.8.0.0/24"

    def test_resolve_injects_table_templates(self):
        """Keyed by content, not position — inserting a table entry must not
        silently move these assertions onto a different rule."""
        spec = resolve_multihop_preset(
            ipv4_subnet="10.8.0.0/24",
            wg_interface="wg_main",
            wg_interface_exit="wg_exit",
        )
        table = spec["table"]
        policies = [e["policy"] for e in table if "policy" in e]
        routes = [e["route"] for e in table if "route" in e]

        steer = [p for p in policies if p["table"] == "mh"]
        assert len(steer) == 1
        assert steer[0]["from"] == "10.8.0.0/24"
        assert steer[0]["priority"] == 100

        route_main = [r for r in routes if r["device"] == "wg_main"]
        assert len(route_main) == 1
        assert route_main[0]["destination"] == "10.8.0.0/24"

        route_exit = [r for r in routes if r["device"] == "wg_exit"]
        assert len(route_exit) == 1
        assert route_exit[0]["destination"] == "default"

    def test_intra_subnet_escape_hatch(self):
        """Priority 99 sends subnet→subnet traffic to the main table before
        the priority-100 rule can steer it into mh. Without it a reply from
        the server (itself inside the subnet) would leave via the exit tunnel.
        Mirrors multihop-v6.yaml, which has carried this rule since v1.0.1."""
        spec = resolve_multihop_preset(
            ipv4_subnet="10.8.0.0/24",
            wg_interface="wg_main",
            wg_interface_exit="wg_exit",
        )
        policies = [e["policy"] for e in spec["table"] if "policy" in e]
        escape = [p for p in policies if p["priority"] == 99]
        assert len(escape) == 1
        assert escape[0]["from"] == "10.8.0.0/24"
        assert escape[0]["to"] == "10.8.0.0/24"
        assert escape[0]["table"] == "main"

    def test_escape_hatch_matches_v6(self):
        """v4 and v6 presets must express the same routing semantics.

        Table names are deliberately not compared: each family gets its own
        routing table (mh / mh6), so only the priorities and the presence of
        the intra-subnet `to` selector are the shared contract.
        """
        v4 = resolve_multihop_preset(ipv4_subnet="10.8.0.0/24")
        v6 = resolve_multihop_v6_preset(ipv6_subnet="fd00:70:68::/120")

        def shape(spec):
            return sorted(
                (p["priority"], "to" in p)
                for e in spec["table"] if "policy" in e
                for p in [e["policy"]]
            )

        assert shape(v4) == shape(v6) == [(99, True), (100, False)]

    def test_uses_default_interface_names(self):
        from phantom_daemon.base.services.wireguard import (
            WG_INTERFACE_NAME,
            WG_INTERFACE_NAME_EXIT,
        )

        spec = resolve_multihop_preset(ipv4_subnet="10.0.0.0/8")
        assert spec["rules"][0]["in_iface"] == WG_INTERFACE_NAME
        assert spec["rules"][0]["out_iface"] == WG_INTERFACE_NAME_EXIT


# ── TestOpenFirewall ─────────────────────────────────────────────


class TestOpenFirewall:
    def test_missing_state_dir(self):
        with pytest.raises(FirewallError, match="State directory"):
            open_firewall(state_dir="/nonexistent/path/to/nowhere")

    def test_creates_service(self, test_env):
        d = test_env.sub("open-svc")
        svc = open_firewall(state_dir=d)
        assert isinstance(svc, FirewallService)
        svc.close()

    def test_db_created(self, test_env):
        d = test_env.sub("open-db")
        svc = open_firewall(state_dir=d)
        assert (Path(d) / "firewall.db").exists()
        svc.close()


# ── TestBootstrap ────────────────────────────────────────────────


class TestBootstrap:
    def test_creates_core_group(self, test_env):
        d = test_env.sub("boot-core")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)
            groups = svc.list_groups()
            names = [g.name for g in groups]
            assert CORE_PRESET_NAME in names

    def test_core_group_type(self, test_env):
        d = test_env.sub("boot-type")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)
            group = svc.get_group(CORE_PRESET_NAME)
            assert group.group_type == "system"

    def test_core_has_six_rules(self, test_env):
        d = test_env.sub("boot-rules")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)
            rules = svc.list_firewall_rules(CORE_PRESET_NAME)
            assert len(rules) == 6

    def test_listen_port_injected(self, test_env):
        d = test_env.sub("boot-port")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)
            rules = svc.list_firewall_rules(CORE_PRESET_NAME)
            udp_rules = [r for r in rules if r.proto == "udp"]
            assert len(udp_rules) == 1
            assert udp_rules[0].dport == test_env.env.listen_port

    def test_interface_injected(self, test_env):
        from phantom_daemon.base.services.wireguard import WG_INTERFACE_NAME

        d = test_env.sub("boot-iface")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)
            rules = svc.list_firewall_rules(CORE_PRESET_NAME)
            fwd_in = [r for r in rules if r.in_iface == WG_INTERFACE_NAME]
            assert len(fwd_in) == 1

    def test_bootstrap_idempotent(self, test_env):
        """Repeated bootstrap replaces the core group — no duplicate rules."""
        d = test_env.sub("boot-idempotent")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)

            cores = [g for g in svc.list_groups() if g.name == CORE_PRESET_NAME]
            assert len(cores) == 1
            assert len(svc.list_firewall_rules(CORE_PRESET_NAME)) == 6

    def test_bootstrap_tracks_wallet_subnet(self, test_env, tmp_path):
        """Masquerade source is re-resolved from the wallet on every bootstrap.

        The core preset bakes {ipv4_subnet}/{ipv6_subnet} at resolve time, so
        a CIDR change only reaches the kernel if bootstrap runs again.
        """
        d = test_env.sub("boot-cidr")
        with open_wallet(str(tmp_path)) as w, open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=w)
            masq = [r for r in svc.list_firewall_rules(CORE_PRESET_NAME)
                    if r.action == "masquerade"]
            assert {r.source for r in masq} == {"10.8.0.0/24", "fd00:70:68::/120"}

            w.change_cidr(22)
            svc.bootstrap(env=test_env.env, wallet=w)

            masq = [r for r in svc.list_firewall_rules(CORE_PRESET_NAME)
                    if r.action == "masquerade"]
            assert {r.source for r in masq} == {"10.8.0.0/22", "fd00:70:68::/118"}


# ── TestResyncMultihop ───────────────────────────────────────────


def _group_names(svc) -> set[str]:
    return {g.name for g in svc.list_groups()}


class TestResyncMultihop:
    def test_v4_only(self, test_env):
        d = test_env.sub("mh-v4")
        with open_firewall(state_dir=d) as svc:
            svc.resync_multihop(wallet=test_env.wallet, has_v4=True, has_v6=False)
            assert _group_names(svc) == {MULTIHOP_PRESET_NAME}

    def test_v6_only(self, test_env):
        """A v6-only exit gets the v6 preset alone — its forward rules are the
        only ones applied, so they are not redundant with the v4 preset's."""
        d = test_env.sub("mh-v6")
        with open_firewall(state_dir=d) as svc:
            svc.resync_multihop(wallet=test_env.wallet, has_v4=False, has_v6=True)
            assert _group_names(svc) == {MULTIHOP_V6_PRESET_NAME}

    def test_dual_stack(self, test_env):
        d = test_env.sub("mh-dual")
        with open_firewall(state_dir=d) as svc:
            svc.resync_multihop(wallet=test_env.wallet, has_v4=True, has_v6=True)
            assert _group_names(svc) == {MULTIHOP_PRESET_NAME, MULTIHOP_V6_PRESET_NAME}

    def test_neither_removes_both(self, test_env):
        """Converge to the requested state — cleans up after a half-done disable."""
        d = test_env.sub("mh-none")
        with open_firewall(state_dir=d) as svc:
            svc.resync_multihop(wallet=test_env.wallet, has_v4=True, has_v6=True)
            svc.resync_multihop(wallet=test_env.wallet, has_v4=False, has_v6=False)
            assert _group_names(svc) == set()

    def test_idempotent(self, test_env):
        d = test_env.sub("mh-idem")
        with open_firewall(state_dir=d) as svc:
            svc.resync_multihop(wallet=test_env.wallet, has_v4=True, has_v6=False)
            rules_first = len(svc.list_firewall_rules(MULTIHOP_PRESET_NAME))
            svc.resync_multihop(wallet=test_env.wallet, has_v4=True, has_v6=False)

            assert _group_names(svc) == {MULTIHOP_PRESET_NAME}
            assert len(svc.list_firewall_rules(MULTIHOP_PRESET_NAME)) == rules_first

    def test_dual_to_v4_drops_v6(self, test_env):
        d = test_env.sub("mh-transition")
        with open_firewall(state_dir=d) as svc:
            svc.resync_multihop(wallet=test_env.wallet, has_v4=True, has_v6=True)
            svc.resync_multihop(wallet=test_env.wallet, has_v4=True, has_v6=False)
            assert _group_names(svc) == {MULTIHOP_PRESET_NAME}

    def test_does_not_touch_core(self, test_env):
        """Core is the base preset — multihop is additive and must not disturb it."""
        d = test_env.sub("mh-core-safe")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)
            svc.resync_multihop(wallet=test_env.wallet, has_v4=True, has_v6=False)
            svc.resync_multihop(wallet=test_env.wallet, has_v4=False, has_v6=False)
            assert CORE_PRESET_NAME in _group_names(svc)
            assert len(svc.list_firewall_rules(CORE_PRESET_NAME)) == 6

    def test_tracks_wallet_subnet(self, test_env, tmp_path):
        """The subnet is baked into three places at resolve time: the policy
        rule that steers traffic into the mh table, the intra-subnet route
        that keeps local traffic local, and the masquerade source."""
        d = test_env.sub("mh-cidr")
        with open_wallet(str(tmp_path)) as w, open_firewall(state_dir=d) as svc:
            w.change_cidr(22)
            svc.resync_multihop(wallet=w, has_v4=True, has_v6=False)

            routing = svc.list_routing_rules(MULTIHOP_PRESET_NAME)
            policy = [r for r in routing if r.rule_type == "policy"]
            # Both the priority-99 escape hatch and the priority-100 steer
            # carry the subnet — a CIDR change has to reach both.
            assert {r.from_network for r in policy} == {"10.8.0.0/22"}
            assert sorted(r.priority for r in policy) == [99, 100]

            local = [r for r in routing
                     if r.rule_type == "route" and r.device == WG_INTERFACE_NAME]
            assert [r.destination for r in local] == ["10.8.0.0/22"]

            masq = [r for r in svc.list_firewall_rules(MULTIHOP_PRESET_NAME)
                    if r.action == "masquerade"]
            assert [r.source for r in masq] == ["10.8.0.0/22"]

    def test_tracks_wallet_subnet_v6(self, test_env, tmp_path):
        d = test_env.sub("mh-cidr-v6")
        with open_wallet(str(tmp_path)) as w, open_firewall(state_dir=d) as svc:
            w.change_cidr(22)
            svc.resync_multihop(wallet=w, has_v4=False, has_v6=True)

            routing = svc.list_routing_rules(MULTIHOP_V6_PRESET_NAME)
            policy = [r for r in routing if r.rule_type == "policy"]
            # priority 99 (intra-subnet escape) + priority 100 (steer to mh6)
            assert {r.from_network for r in policy} == {"fd00:70:68::/118"}
            assert sorted(r.priority for r in policy) == [99, 100]

            masq = [r for r in svc.list_firewall_rules(MULTIHOP_V6_PRESET_NAME)
                    if r.action == "masquerade"]
            assert [r.source for r in masq] == ["fd00:70:68::/118"]


# ── TestLifecycle ────────────────────────────────────────────────


class TestLifecycle:
    def test_start_stop(self, test_env):
        d = test_env.sub("lifecycle")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)
            svc.start()
            assert svc.get_state() == "started"
            svc.stop()
            assert svc.get_state() == "stopped"

    def test_context_manager(self, test_env):
        d = test_env.sub("ctx-mgr")
        with open_firewall(state_dir=d) as svc:
            assert isinstance(svc, FirewallService)
        # close called implicitly — no error

    def test_recover_from_db(self, test_env):
        """Second open on same DB recovers groups without bootstrap."""
        d = test_env.sub("recover")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)

        with open_firewall(state_dir=d) as svc2:
            groups = svc2.list_groups()
            assert len(groups) >= 1
            assert any(g.name == CORE_PRESET_NAME for g in groups)


# ── TestPresetOperations ─────────────────────────────────────────


class TestPresetOperations:
    def test_apply_custom_preset(self, test_env):
        d = test_env.sub("preset-apply")
        spec = {
            "name": "test-custom",
            "priority": 90,
            "type": "custom",
            "metadata": {"description": "test"},
            "rules": [
                {
                    "chain": "input",
                    "action": "drop",
                    "proto": "tcp",
                    "dport": 9999,
                },
            ],
        }
        with open_firewall(state_dir=d) as svc:
            group = svc.apply_preset(spec)
            assert group.name == "test-custom"

    def test_remove_preset(self, test_env):
        d = test_env.sub("preset-rm")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)
            svc.remove_preset(CORE_PRESET_NAME)
            names = [g.name for g in svc.list_groups()]
            assert CORE_PRESET_NAME not in names

    def test_disable_enable_preset(self, test_env):
        d = test_env.sub("preset-toggle")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)
            svc.disable_preset(CORE_PRESET_NAME)
            group = svc.get_group(CORE_PRESET_NAME)
            assert group.enabled is False

            svc.enable_preset(CORE_PRESET_NAME)
            group = svc.get_group(CORE_PRESET_NAME)
            assert group.enabled is True

    def test_apply_preserves_existing(self, test_env):
        d = test_env.sub("preset-preserve")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)
            extra = {
                "name": "extra",
                "priority": 90,
                "type": "custom",
                "metadata": {"description": "extra"},
                "rules": [
                    {
                        "chain": "input",
                        "action": "drop",
                        "proto": "tcp",
                        "dport": 8888,
                    },
                ],
            }
            svc.apply_preset(extra)
            names = [g.name for g in svc.list_groups()]
            assert CORE_PRESET_NAME in names
            assert "extra" in names


# ── TestReadOperations ───────────────────────────────────────────


class TestReadOperations:
    def test_list_firewall_rules(self, test_env):
        d = test_env.sub("read-fw-rules")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)
            rules = svc.list_firewall_rules()
            assert len(rules) == 6
            chains = {r.chain for r in rules}
            assert "input" in chains
            assert "postrouting" in chains

    def test_list_firewall_rules_filtered(self, test_env):
        d = test_env.sub("read-fw-filtered")
        with open_firewall(state_dir=d) as svc:
            svc.bootstrap(env=test_env.env, wallet=test_env.wallet)
            rules = svc.list_firewall_rules(CORE_PRESET_NAME)
            assert len(rules) == 6
