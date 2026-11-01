"""
R5: presets from YAML files through the preset API.

Drives: apply_preset with each file of scenarios/ as a Path, started then
applied and applied then started; disable_preset, enable_preset twice,
stop() and start(); remove_preset; a preset removed and applied again with
other networks while started, as the daemon's change_cidr does; every
preset at once, applied against its priority order, then a new
FirewallBridge on the same database; the daemon's boot order (presets
while stopped, then start) and what follows it; two exits in two tables,
one removed. The scenarios: the daemon's core and multihop presets with
the rule stage's names, and port forwarding, per-peer forwarding, IPv6
services, a reject set, two exits and three groups on one port. After
every step the invariants of oracle.check hold, with inet reference
written from the rules below, and the routing rows are the kernel's
(oracle.assert_routing_matches_db); the routing a preset made equals what
its ip commands below make by hand. The IPv6 services preset holds a
family 10 rule without an address, written below without an ip6 match.

Does not show: presets the schema or the kernel refuses, and presets that
want the same route (R8); templates (the daemon resolves them); a process
that ends while it applies a preset (R7); packets.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from firewall_bridge import FirewallBridge
from firewall_bridge.presets import disable_preset, enable_preset, get_preset

from e2e_tests.rules import oracle
from e2e_tests.rules.oracle import PHANTOM

SCENARIOS = Path(__file__).parent / "scenarios"
INTERFACES = ("r5main", "r5exit", "r5exit2")

# File name → (its rules as nft takes them, in the file's order; the ip
# commands that make what its table entries make).
PRESETS = {
    "core": ([
        "input udp dport 51820 accept",
        "input ct state established,related accept",
        'forward iifname "r5main" accept',
        'forward oifname "r5main" ct state established,related accept',
        "postrouting ip saddr 10.8.0.0/24 masquerade",
        "postrouting ip6 saddr fd00:70:68::/120 masquerade",
    ], []),
    "multihop": ([
        'forward iifname "r5main" oifname "r5exit" accept',
        'forward iifname "r5exit" oifname "r5main" ct state established,related accept',
        'postrouting oifname "r5exit" ip saddr 10.8.0.0/24 masquerade',
    ], [
        ["rule", "add", "from", "10.8.0.0/24", "to", "10.8.0.0/24", "lookup", "main",
         "priority", "5099"],
        ["rule", "add", "from", "10.8.0.0/24", "lookup", "150", "priority", "5100"],
        ["route", "add", "10.8.0.0/24", "dev", "r5main", "table", "150", "proto", "static"],
        ["route", "add", "default", "dev", "r5exit", "table", "150", "proto", "static"],
    ]),
    "multihop-v6": ([
        'forward iifname "r5main" oifname "r5exit" accept',
        'forward iifname "r5exit" oifname "r5main" ct state established,related accept',
        'postrouting oifname "r5exit" ip6 saddr fd00:70:68::/120 masquerade',
    ], [
        ["-6", "rule", "add", "from", "fd00:70:68::/120", "to", "fd00:70:68::/120", "lookup",
         "main", "priority", "5099"],
        ["-6", "rule", "add", "from", "fd00:70:68::/120", "lookup", "151", "priority", "5100"],
        ["-6", "route", "add", "fd00:70:68::/120", "dev", "r5main", "table", "151", "proto",
         "static"],
        ["-6", "route", "add", "default", "dev", "r5exit", "table", "151", "proto", "static"],
    ]),
    "port-forward": ([
        'prerouting iifname "r5pub" tcp dport 8443 dnat ip to 10.8.0.5:443',
        'prerouting iifname "r5pub" udp dport 5353 dnat ip to 10.8.0.6',
        'prerouting iifname "r5pub" tcp dport 8443 dnat ip6 to [fd00:70:68::5]:443',
        'forward iifname "r5pub" oifname "r5main" ip daddr 10.8.0.5 tcp dport 443 ct state new accept',
        'forward iifname "r5pub" oifname "r5main" ip6 daddr fd00:70:68::5 tcp dport 443 '
        'ct state new accept',
    ], []),
    "per-peer": ([
        'forward iifname "r5main" oifname "r5exit" ip saddr 10.8.0.2 accept',
        'forward iifname "r5main" oifname "r5exit" ip saddr 10.8.0.3 drop',
        'forward iifname "r5main" oifname "r5exit" ip6 saddr fd00:70:68::2 accept',
        'forward iifname "r5main" oifname "r5main" drop',
    ], []),
    "v6-services": ([
        "input ip6 saddr fd00:70:68::/120 tcp dport 22 accept",
        "input ip6 saddr fd00:70:68::/120 udp dport 53 accept",
        "input ip6 daddr fd00:70:68::1 tcp dport 443 ct state new accept",
        "input tcp dport 2222 reject",
    ], []),
    "reject-set": ([
        "output tcp dport 25 reject",
        "input ip saddr 192.0.2.0/24 tcp dport 3389 drop",
        "forward ip daddr 198.51.100.0/24 udp dport 53 reject",
        "input ip6 saddr 2001:db8:bad::/48 tcp dport 3389 drop",
    ], []),
    "exit-one": ([
        'forward iifname "r5main" oifname "r5exit" ip saddr 10.8.0.2 accept',
        'postrouting oifname "r5exit" ip saddr 10.8.0.2 masquerade',
    ], [
        ["rule", "add", "from", "10.8.0.2/32", "lookup", "152", "priority", "5200"],
        ["route", "add", "default", "dev", "r5exit", "table", "152", "proto", "static"],
    ]),
    "exit-two": ([
        'forward iifname "r5main" oifname "r5exit2" ip saddr 10.8.0.3 accept',
        'postrouting oifname "r5exit2" ip saddr 10.8.0.3 masquerade',
    ], [
        ["rule", "add", "from", "10.8.0.3/32", "lookup", "153", "priority", "5201"],
        ["route", "add", "default", "dev", "r5exit2", "table", "153", "proto", "static"],
    ]),
    "layered-allow": (["input ip saddr 10.8.0.0/24 tcp dport 22 accept"], []),
    "layered-deny": (["input ip saddr 10.8.0.3 tcp dport 22 drop"], []),
    "layered-default": (["input tcp dport 22 reject"], []),
}

# The daemon's change_cidr: the networks of core and multihop, other ones.
CHANGED = {"10.8.0.0/24": "10.9.0.0/23", "fd00:70:68::/120": "fd00:70:68::/119"}
DAEMON = ("core", "multihop", "multihop-v6")


@pytest.fixture(autouse=True)
def interfaces():
    """The scenarios' devices; routing of the rule stage cleared around."""
    oracle.clear_routing()
    for name in INTERFACES:
        oracle.run([oracle.IP, "link", "add", name, "type", "dummy"])
        oracle.run([oracle.IP, "link", "set", name, "up"])
    yield
    oracle.clear_routing()
    for name in INTERFACES:
        oracle.run([oracle.IP, "link", "del", name])


def _check(bridge, db_path, meter, ledger):
    oracle.check(bridge, db_path, meter, ledger)
    oracle.assert_routing_matches_db(db_path)


def _spec(name: str) -> dict:
    return yaml.safe_load((SCENARIOS / f"{name}.yaml").read_text())


def _changed(text: str) -> str:
    for old, new in CHANGED.items():
        text = text.replace(old, new)
    return text


def _changed_file(name: str, tmp_path: Path) -> Path:
    path = tmp_path / f"{name}.yaml"
    path.write_text(_changed((SCENARIOS / f"{name}.yaml").read_text()))
    return path


def _ip(commands):
    for command in commands:
        oracle.run([oracle.IP, *command])


def _first_verdict(chain: str) -> str:
    return next(iter(oracle.read_table(PHANTOM).rules[chain][0]["expr"][-1]))


@pytest.mark.parametrize("order", ["started-then-apply", "applied-then-start"])
@pytest.mark.parametrize("name", list(PRESETS))
def test_one_preset(bridge, db_path, meter, order, name):
    rules, commands = PRESETS[name]
    spec = _spec(name)
    ledger = oracle.Ledger(bridge)
    if order == "started-then-apply":
        bridge.start()
    group = ledger.apply_preset(SCENARIOS / f"{name}.yaml", rules)
    _check(bridge, db_path, meter, ledger)
    if order == "applied-then-start":
        bridge.start()
        ledger.started()
        _check(bridge, db_path, meter, ledger)
    stored = get_preset(bridge, group.name)
    assert (stored.name, stored.group_type, stored.priority, stored.metadata) == (
        spec["name"], spec.get("type", "custom"), spec["priority"], spec["metadata"])
    made = oracle.routing_state()
    assert (made != ([], {})) == bool(commands), made

    for step in (lambda: disable_preset(bridge, group.name),
                 lambda: enable_preset(bridge, group.name),
                 lambda: enable_preset(bridge, group.name),
                 bridge.stop, bridge.start):
        step()
        ledger.sync()
        _check(bridge, db_path, meter, ledger)
    assert oracle.routing_state() == made

    ledger.remove_preset(group.name)
    _check(bridge, db_path, meter, ledger)
    assert oracle.routing_state() == ([], {})
    _ip(commands)
    assert oracle.routing_state() == made


@pytest.mark.parametrize("name", DAEMON)
def test_networks_changed_while_started(bridge, db_path, meter, tmp_path, name):
    rules, commands = PRESETS[name]
    ledger = oracle.Ledger(bridge)
    bridge.start()
    group = ledger.apply_preset(SCENARIOS / f"{name}.yaml", rules)
    before = oracle.routing_state()

    ledger.remove_preset(group.name)
    _check(bridge, db_path, meter, ledger)
    ledger.apply_preset(_changed_file(name, tmp_path), [_changed(r) for r in rules])
    _check(bridge, db_path, meter, ledger)
    made = oracle.routing_state()
    assert not commands or made != before, "the networks did not change"

    bridge.stop()
    ledger.stopped()
    _check(bridge, db_path, meter, ledger)
    bridge.start()
    ledger.started()
    _check(bridge, db_path, meter, ledger)
    ledger.remove_preset(group.name)
    _ip([[_changed(part) for part in command] for command in commands])
    assert oracle.routing_state() == made


def test_every_preset_at_once(bridge, db_path, meter):
    """Applied from the highest priority to the lowest, so no group is made
    in its place; the kernel holds them by priority."""
    ledger = oracle.Ledger(bridge)
    bridge.start()
    names = sorted(PRESETS, key=lambda n: _spec(n)["priority"], reverse=True)
    groups = [ledger.apply_preset(SCENARIOS / f"{n}.yaml", PRESETS[n][0]) for n in names]
    _check(bridge, db_path, meter, ledger)
    assert _first_verdict("input") == "accept"
    assert [g.name for g in bridge.list_groups()] != [g.name for g in groups]

    bridge.stop()
    ledger.stopped()
    _check(bridge, db_path, meter, ledger)
    bridge.start()
    ledger.started()
    _check(bridge, db_path, meter, ledger)

    second = FirewallBridge(db_path)
    try:
        ledger.bridge = second
        second.start()
        ledger.started()
        _check(second, db_path, meter, ledger)
        for group in groups:
            ledger.remove_preset(group.name)
            _check(second, db_path, meter, ledger)
        assert oracle.routing_state() == ([], {})
    finally:
        second.close()


def test_the_daemon_order(bridge, db_path, meter, tmp_path):
    """main.py's boot: core and multihop applied while stopped, then
    start(); network/api.py's change_cidr; multihop/api.py's disable and
    enable; stop() and start()."""
    ledger = oracle.Ledger(bridge)
    groups = [ledger.apply_preset(SCENARIOS / f"{n}.yaml", PRESETS[n][0]) for n in DAEMON]
    _check(bridge, db_path, meter, ledger)
    bridge.start()
    ledger.started()
    _check(bridge, db_path, meter, ledger)

    def changed(name):
        ledger.apply_preset(_changed_file(name, tmp_path), [_changed(r) for r in PRESETS[name][0]])
        _check(bridge, db_path, meter, ledger)

    def multihop_off():
        for group in groups[1:]:
            ledger.remove_preset(group.name)
            _check(bridge, db_path, meter, ledger)

    ledger.remove_preset(groups[0].name)       # bootstrap
    changed("core")
    multihop_off()                             # resync_multihop
    for name in DAEMON[1:]:
        changed(name)
    multihop_off()                             # disable_multihop
    for name in DAEMON[1:]:                    # enable
        changed(name)

    bridge.stop()
    ledger.stopped()
    _check(bridge, db_path, meter, ledger)
    bridge.start()
    ledger.started()
    _check(bridge, db_path, meter, ledger)


def test_two_exits_one_removed(bridge, db_path, meter):
    ledger = oracle.Ledger(bridge)
    bridge.start()
    for name in ("exit-one", "exit-two"):
        ledger.apply_preset(SCENARIOS / f"{name}.yaml", PRESETS[name][0])
    assert sorted(oracle.routing_state()[1]) == [152, 153]
    ledger.remove_preset("exit-one")
    _check(bridge, db_path, meter, ledger)
    rules, routes = oracle.routing_state()
    assert ([r["priority"] for r in rules], list(routes)) == ([5201], [153])


# ── The preset ledger, before it judges the bridge ───────────────

def test_the_check_finds_a_preset_rule_out_of_its_place(bridge, db_path, meter):
    ledger = oracle.Ledger(bridge)
    bridge.start()
    ledger.apply_preset(SCENARIOS / "per-peer.yaml", PRESETS["per-peer"][0][::-1])
    with pytest.raises(AssertionError, match="forward differs"):
        oracle.check(bridge, db_path, meter, ledger)
