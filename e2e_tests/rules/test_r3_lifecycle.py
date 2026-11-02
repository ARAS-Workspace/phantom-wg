"""
R3: groups, priorities and the bridge's lifecycle.

Drives: three groups of priorities 10, 20 and 30 whose rules share chains
and whose verdicts differ (accept, drop, reject on the same port), added
interleaved, started then added and added then started; enable_group and
disable_group in every order; delete_group and the group made again;
remove_firewall_rule across groups; enable_group while stopped; a preset
applied while started; stop() and start(); a new FirewallBridge on the
same database while the kernel still holds the last one's rules; and a
second Python process that starts a bridge on the database and exits
without stop(); an ip and an inet table of another owner beside inet
phantom through start, changes, stop and start. After every step the three
invariants of oracle.check hold, with inet reference built in group
priority order.

Does not show: routing rows (R4); presets beyond their group order (R5);
size (R6); changes made from outside the bridge (R7); a kernel that
refuses a rule (R8). No packet is sent: which verdict the kernel reaches
first is read from the rule order, not from traffic.
"""

from __future__ import annotations

import subprocess
import sys

import pytest

from firewall_bridge import FirewallBridge
from firewall_bridge.presets import apply_preset

from e2e_tests.rules import oracle
from e2e_tests.rules.oracle import PHANTOM

# Made in this order, so the order of their ids is not their priority order.
GROUPS = {"low": 30, "high": 10, "mid": 20}

# (group, add_firewall_rule fields, the same rule as nft takes it), in the
# order they are added: the groups interleaved.
RULES = [
    ("low", dict(chain="input", action="reject", proto="tcp", dport=8080),
     "input tcp dport 8080 reject"),
    ("high", dict(chain="input", action="accept", proto="tcp", dport=8080),
     "input tcp dport 8080 accept"),
    ("mid", dict(chain="input", action="drop", proto="tcp", dport=8080),
     "input tcp dport 8080 drop"),
    ("low", dict(chain="forward", action="accept", in_iface="wg0"),
     'forward iifname "wg0" accept'),
    ("high", dict(chain="forward", action="drop", in_iface="wg0", out_iface="eth0"),
     'forward iifname "wg0" oifname "eth0" drop'),
    ("mid", dict(chain="postrouting", action="masquerade", source="10.0.1.0/24"),
     "postrouting ip saddr 10.0.1.0/24 masquerade"),
    ("high", dict(chain="postrouting", action="masquerade", source="10.0.1.0/24",
                  out_iface="wg_exit"),
     'postrouting oifname "wg_exit" ip saddr 10.0.1.0/24 masquerade'),
]


def _groups(bridge):
    for name, priority in GROUPS.items():
        bridge.create_group(name, priority=priority)


def _first_verdict(chain: str) -> str:
    """The verdict of the first rule in `chain` of inet phantom."""
    first = oracle.read_table(PHANTOM).rules[chain][0]["expr"][-1]
    return next(iter(first))


@pytest.mark.parametrize("order", ["started-then-add", "added-then-start"])
def test_groups_land_in_priority_order(bridge, db_path, meter, order):
    _groups(bridge)
    ledger = oracle.Ledger(bridge)
    if order == "started-then-add":
        bridge.start()
    for group, fields, rule in RULES:
        ledger.add(group, rule, **fields)
        oracle.check(bridge, db_path, meter, ledger)
    if order == "added-then-start":
        bridge.start()
        ledger.started()
        oracle.check(bridge, db_path, meter, ledger)
    assert _first_verdict("input") == "accept"
    assert _first_verdict("forward") == "drop"


def test_enable_and_disable_in_every_order(bridge, db_path, meter):
    _groups(bridge)
    ledger = oracle.Ledger(bridge)
    bridge.start()
    for group, fields, rule in RULES:
        ledger.add(group, rule, **fields)
    steps = [("disable", "mid"), ("enable", "mid"), ("disable", "high"), ("enable", "high"),
             ("disable", "low"), ("disable", "high"), ("disable", "mid"),
             ("enable", "low"), ("enable", "mid"), ("enable", "high"),
             ("enable", "high")]
    for action, group in steps:
        getattr(ledger, action)(group)
        oracle.check(bridge, db_path, meter, ledger)
    assert _first_verdict("input") == "accept"


def test_a_group_deleted_and_made_again(bridge, db_path, meter):
    _groups(bridge)
    ledger = oracle.Ledger(bridge)
    bridge.start()
    for group, fields, rule in RULES:
        ledger.add(group, rule, **fields)
    ledger.delete_group("high")
    oracle.check(bridge, db_path, meter, ledger)
    assert _first_verdict("input") == "drop"

    bridge.create_group("high", priority=GROUPS["high"])
    for group, fields, rule in RULES:
        if group == "high":
            ledger.add(group, rule, **fields)
            oracle.check(bridge, db_path, meter, ledger)
    assert _first_verdict("input") == "accept"


def test_rules_removed_across_groups(bridge, db_path, meter):
    _groups(bridge)
    ledger = oracle.Ledger(bridge)
    bridge.start()
    ids = [ledger.add(group, rule, **fields) for group, fields, rule in RULES]
    for rule_id in ids[::2] + ids[1::2]:
        ledger.remove(rule_id)
        oracle.check(bridge, db_path, meter, ledger)


def test_groups_changed_while_stopped(bridge, db_path, meter):
    _groups(bridge)
    ledger = oracle.Ledger(bridge)
    for group, fields, rule in RULES:
        ledger.add(group, rule, **fields)
    ledger.disable("high")
    bridge.start()
    ledger.started()
    oracle.check(bridge, db_path, meter, ledger)
    assert _first_verdict("input") == "drop"

    bridge.stop()
    ledger.stopped()
    ledger.enable("high")
    ledger.disable("low")
    oracle.check(bridge, db_path, meter, ledger)
    bridge.start()
    ledger.started()
    oracle.check(bridge, db_path, meter, ledger)
    assert _first_verdict("input") == "accept"


def test_a_preset_applied_while_started_lands_in_its_place(bridge, db_path, meter):
    _groups(bridge)
    ledger = oracle.Ledger(bridge)
    bridge.start()
    for group, fields, rule in RULES:
        if group != "high":
            ledger.add(group, rule, **fields)
    apply_preset(bridge, {"name": "first", "priority": 5, "rules": [
        {"chain": "input", "action": "accept", "proto": "tcp", "dport": 8080}]})
    (row,) = bridge.list_firewall_rules("first")
    ledger.texts[row.id] = "input tcp dport 8080 accept"
    ledger.reference[row.id] = None
    ledger.sync()
    oracle.check(bridge, db_path, meter, ledger)
    assert _first_verdict("input") == "accept"


def test_tables_of_others_are_left_as_they_are(bridge, db_path, meter):
    """An ip table and an inet table of another owner, with a base chain and
    a rule each, through the bridge's start, changes, stop and start again."""
    for family in ("ip", "inet"):
        oracle.nft(f"add table {family} r3other")
        oracle.nft(f"add chain {family} r3other c {{ type filter hook input priority 10; "
                   "policy accept; }")
        oracle.nft(f"add rule {family} r3other c tcp dport 7 drop")
    try:
        listing = lambda: [oracle.nft(f"list table {family} r3other") for family in ("ip", "inet")]
        made = listing()
        _groups(bridge)
        ledger = oracle.Ledger(bridge)
        for group, fields, rule in RULES:
            ledger.add(group, rule, **fields)
        bridge.start()
        ledger.started()
        steps = [lambda: ledger.disable("mid"), lambda: ledger.enable("mid"),
                 lambda: ledger.delete_group("low"), lambda: (bridge.stop(), ledger.stopped()),
                 lambda: (bridge.start(), ledger.started())]
        for step in steps:
            step()
            oracle.check(bridge, db_path, meter, ledger)
            assert listing() == made
        assert {"ip r3other", "inet r3other"} <= set(oracle.foreign_tables())
    finally:
        for family in ("ip", "inet"):
            subprocess.run([oracle.NFT, f"delete table {family} r3other"], capture_output=True,
                           check=False)


def test_a_new_bridge_on_the_same_database(bridge, db_path, meter):
    """The first bridge is left started, without stop(): the kernel holds its
    rules, the new bridge holds none applied until start() replaces them."""
    _groups(bridge)
    ledger = oracle.Ledger(bridge)
    bridge.start()
    for group, fields, rule in RULES:
        ledger.add(group, rule, **fields)
    before = oracle.read_table(PHANTOM)

    second = FirewallBridge(db_path)
    try:
        assert second.get_state() == "stopped"
        assert not any(r.applied for r in second.list_firewall_rules())
        assert oracle.read_table(PHANTOM).rules == before.rules
        ledger.bridge = second
        second.start()
        ledger.started()
        oracle.check(second, db_path, meter, ledger)
    finally:
        second.close()


SECOND_PROCESS = """
import sys
from firewall_bridge import FirewallBridge
b = FirewallBridge(sys.argv[1])
b.start()
print(len(b.list_firewall_rules()))
"""


def test_another_process_left_its_rules(bridge, db_path, meter):
    """A second process starts a bridge on the database and exits without
    stop(); this process's bridge then starts on the same database."""
    _groups(bridge)
    ledger = oracle.Ledger(bridge)
    for group, fields, rule in RULES:
        ledger.add(group, rule, **fields)
    bridge.close()

    out = subprocess.run([sys.executable, "-c", SECOND_PROCESS, db_path],
                         capture_output=True, text=True, check=True)
    assert out.stdout.strip() == str(len(RULES))
    assert sum(len(r) for r in oracle.read_table(PHANTOM).rules.values()) == len(RULES)

    third = FirewallBridge(db_path)
    try:
        ledger.bridge = third
        third.start()
        ledger.started()
        oracle.check(third, db_path, meter, ledger)
    finally:
        third.close()
