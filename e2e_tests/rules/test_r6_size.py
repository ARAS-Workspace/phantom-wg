"""
R6: size, thousands of rules and hundreds of routing rows.

Drives: start() over 189 and 2000 rules of the longest shape with a
128-byte comment, added while stopped (188 of them fill 128 KiB, the most
one argument holds; the command goes to nft on its stdin); 1000 and 5000
rules of six shapes in ten presets made in an order that is not their
priority order, started then applied and applied then started; stop() and
start(); a new FirewallBridge on the same database; half the presets
disabled and enabled; every preset removed; five presets of 100 policy
rules and 100 routes each, the same routing then made with one `ip -batch`
run; three cycles of 5000 rules applied and removed with no check in
between, the resident memory at the end of the second and third within
8 MiB of the first. After every step the invariants of oracle.check hold,
with inet reference written in one nft run from oracle.rule_text, and the
routing rows are the kernel's (oracle.assert_routing_matches_db).
rule_text is first held to the rules written by hand in R1, R2 and R5.

Does not show: more than 5000 rules or 500 routing rows; the time a step
takes (printed, not bounded); rules added one at a time while started at
this size (each rebuilds the table); packets.
"""

from __future__ import annotations

import subprocess

import pytest
import yaml

from firewall_bridge import FirewallBridge
from firewall_bridge.presets import apply_preset, disable_preset, enable_preset, remove_preset

from e2e_tests.rules import oracle
from e2e_tests.rules.oracle import PHANTOM
from e2e_tests.rules.test_r1_single_field import CASES as R1
from e2e_tests.rules.test_r2_combined import CASES as R2
from e2e_tests.rules.test_r5_presets import PRESETS as R5, SCENARIOS

# Made in this order; none is in its place.
PRIORITIES = (90, 10, 50, 30, 70, 20, 80, 40, 60, 100)


@pytest.fixture(autouse=True)
def device():
    oracle.clear_routing()
    oracle.run([oracle.IP, "link", "add", "r6main", "type", "dummy"])
    oracle.run([oracle.IP, "link", "set", "r6main", "up"])
    yield
    oracle.clear_routing()
    oracle.run([oracle.IP, "link", "del", "r6main"])


def _check(bridge, db_path, meter, ledger):
    oracle.check(bridge, db_path, meter, ledger)
    oracle.assert_routing_matches_db(db_path)


def _kernel_rules() -> int:
    return sum(len(rules) for rules in oracle.read_table(PHANTOM).rules.values())


def _longest(i: int) -> dict:
    return dict(chain="forward", action="accept", in_iface="wg_phantom_main",
                out_iface="wg_phantom_exit", source=f"10.8.{i // 256}.{i % 256}/32",
                proto="tcp", dport=443, state_match="new,established",
                comment=f"r6 {i:06d} " + "x" * 118)


def _rule(group: int, i: int) -> dict:
    """The i-th rule of a group, in six shapes."""
    host = f"10.{60 + group}.{i // 256 % 256}.{i % 256}"
    port = 1 + i % 65535
    return [
        {"chain": "forward", "action": "accept", "in_iface": "wg_phantom_main",
         "out_iface": "wg_phantom_exit", "source": f"{host}/32", "proto": "tcp", "dport": port,
         "state": "new"},
        {"chain": "forward", "action": "drop", "family": 10, "source": f"fd00:{group:x}:{i:x}::/64",
         "proto": "udp", "dport": 53},
        {"chain": "postrouting", "action": "masquerade", "out_iface": "wg_phantom_exit",
         "source": f"10.{60 + group}.{i % 256}.0/24"},
        {"chain": "prerouting", "action": f"dnat to {host}:443", "in_iface": "r6pub",
         "proto": "tcp", "dport": port},
        {"chain": "input", "action": "reject", "source": f"192.0.{group}.{i % 256}/32",
         "proto": "tcp", "dport": port},
        {"chain": "forward", "action": "accept", "in_iface": "wg_phantom_exit",
         "out_iface": "wg_phantom_main", "state": "established,related"},
    ][i % 6]


def _specs(size: int) -> list[dict]:
    per = size // len(PRIORITIES)
    return [{"name": f"r6g{g}", "priority": p, "rules": [_rule(g, i) for i in range(per)]}
            for g, p in enumerate(PRIORITIES)]


def test_the_builder_writes_the_hand_written_rules():
    cases = [(fields, text) for _, fields, text in R1 + R2]
    for name, (texts, _) in R5.items():
        rules = yaml.safe_load((SCENARIOS / f"{name}.yaml").read_text()).get("rules", [])
        cases += list(zip(rules, texts))
    assert len(cases) == len(R1) + len(R2) + sum(len(texts) for texts, _ in R5.values())
    assert [oracle.rule_text(fields) for fields, _ in cases] == [text for _, text in cases]


@pytest.mark.parametrize("size", [189, 2000])
def test_start_past_one_argument(bridge, db_path, meter, size):
    """The rules go in while stopped; start() puts all of them in one run."""
    bridge.create_group("r6")
    ledger = oracle.Ledger(bridge)
    for i in range(size):
        fields = _longest(i)
        rule_id = bridge.add_firewall_rule("r6", **fields)
        ledger.texts[rule_id] = oracle.rule_text(fields)
        ledger.reference[rule_id] = None
    bridge.start()
    ledger.started()
    _check(bridge, db_path, meter, ledger)
    assert _kernel_rules() == size

    bridge.stop()
    ledger.stopped()
    _check(bridge, db_path, meter, ledger)
    second = FirewallBridge(db_path)
    try:
        ledger.bridge = second
        second.start()
        ledger.started()
        _check(second, db_path, meter, ledger)
        assert _kernel_rules() == size
    finally:
        second.close()


@pytest.mark.parametrize("order", ["started-then-apply", "applied-then-start"])
@pytest.mark.parametrize("size", [1000, 5000])
def test_presets_by_the_thousand(bridge, db_path, meter, order, size):
    ledger = oracle.Ledger(bridge)
    if order == "started-then-apply":
        bridge.start()
    groups = [ledger.apply_preset(spec, [oracle.rule_text(r) for r in spec["rules"]])
              for spec in _specs(size)]
    if order == "applied-then-start":
        bridge.start()
        ledger.started()
    _check(bridge, db_path, meter, ledger)
    assert _kernel_rules() == size
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
        for switch in (disable_preset, enable_preset):
            for group in groups[::2]:
                switch(second, group.name)
                ledger.sync()
                _check(second, db_path, meter, ledger)
        for group in groups:
            ledger.remove_preset(group.name)
            _check(second, db_path, meter, ledger)
        assert _kernel_rules() == 0
    finally:
        second.close()


def _rss_kb() -> int:
    with open("/proc/self/status") as f:
        return int(next(line for line in f if line.startswith("VmRSS")).split()[1])


def test_the_bridge_grows_no_memory_over_cycles(bridge, db_path, meter):
    bridge.start()
    ends = []
    for _ in range(3):
        specs = _specs(5000)
        for spec in specs:
            apply_preset(bridge, spec)
        assert _kernel_rules() == 5000
        for spec in specs:
            remove_preset(bridge, spec["name"])
        ends.append(_rss_kb())
    assert max(ends[1:]) <= ends[0] + 8 * 1024, f"resident kB at the cycle ends: {ends}"
    _check(bridge, db_path, meter, oracle.Ledger(bridge))
    assert _kernel_rules() == 0


def test_routing_by_the_hundred(bridge, db_path, meter):
    ledger = oracle.Ledger(bridge)
    bridge.start()
    groups, commands = [], []
    for g in range(5):
        table, name = 150 + g, f"r6t{g}"
        entries = [{"ensure": {"id": table, "name": name}}]
        for i in range(100):
            priority = 5000 + 100 * g + i
            entries += [{"policy": {"from": f"10.70.{g}.{i}/32", "table": name, "priority": priority}},
                        {"route": {"destination": f"10.71.{g}.{i}/32", "device": "r6main",
                                   "table": name}}]
            commands += [f"rule add from 10.70.{g}.{i}/32 lookup {table} priority {priority}",
                         f"route add 10.71.{g}.{i}/32 dev r6main table {table} proto static"]
        groups.append(ledger.apply_preset({"name": f"r6route{g}", "priority": 10 + g,
                                           "table": entries}, []))
        _check(bridge, db_path, meter, ledger)
    made = oracle.routing_state()
    assert (len(made[0]), sum(len(r) for r in made[1].values())) == (500, 500)

    bridge.stop()
    ledger.stopped()
    _check(bridge, db_path, meter, ledger)
    assert oracle.routing_state() == ([], {})
    second = FirewallBridge(db_path)
    try:
        ledger.bridge = second
        second.start()
        ledger.started()
        _check(second, db_path, meter, ledger)
        assert oracle.routing_state() == made
        for group in groups:
            ledger.remove_preset(group.name)
            _check(second, db_path, meter, ledger)
        assert oracle.routing_state() == ([], {})
    finally:
        second.close()

    subprocess.run([oracle.IP, "-batch", "-"], input="\n".join(commands) + "\n",
                   text=True, check=True)
    assert oracle.routing_state() == made
