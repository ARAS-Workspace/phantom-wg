"""
R2: rules with several fields, nat and comments, through the bridge and
through nft, in both orders the bridge applies rules.

Drives: add_firewall_rule on a started bridge, and add_firewall_rule on a
stopped bridge followed by start(), the order the daemon boots in; then
stop() and start() with the rules in place, and remove_firewall_rule.
Cases: the forwarding, masquerade and listen rules of the daemon's core
and multihop presets, a forward rule with five matches, dnat with a
port, an address and an interface in IPv4 and IPv6, reject with a
network and a port, and comments in ASCII, Turkish, Chinese, an emoji
and at 128 bytes. Each case's nft rule is written out below by hand.
After every step the three invariants of oracle.check hold.

Also: the bridge's field order against the same matches in another
order, the table's text listing loaded back with `nft -f`, a quoted
comment's listing that does not load, and comments the bridge refuses.

Does not show: several groups, priorities, enable and disable (R3);
routing (R4); presets (R5); size (R6); changes made from outside the
bridge (R7); a kernel that refuses a rule (R8). No packet is sent.
"""

from __future__ import annotations

import json
import subprocess

import pytest

from firewall_bridge import InvalidParamError

from e2e_tests.rules import oracle
from e2e_tests.rules.oracle import PHANTOM, REFERENCE

# (id, add_firewall_rule fields, the same rule as nft takes it)
CASES = [
    ("multihop-forward",
     dict(chain="forward", action="accept", in_iface="wg_main", out_iface="wg_exit"),
     'forward iifname "wg_main" oifname "wg_exit" accept'),
    ("multihop-return",
     dict(chain="forward", action="accept", in_iface="wg_exit", out_iface="wg_main",
          state_match="established,related"),
     'forward iifname "wg_exit" oifname "wg_main" ct state established,related accept'),
    ("multihop-masquerade",
     dict(chain="postrouting", action="masquerade", source="10.0.1.0/24", out_iface="wg_exit"),
     'postrouting oifname "wg_exit" ip saddr 10.0.1.0/24 masquerade'),
    ("multihop-masquerade-v6",
     dict(chain="postrouting", action="masquerade", family=10, source="fd00:10:1::/64",
          out_iface="wg_exit"),
     'postrouting oifname "wg_exit" ip6 saddr fd00:10:1::/64 masquerade'),
    ("core-listen",
     dict(chain="input", action="accept", proto="udp", dport=51820),
     "input udp dport 51820 accept"),
    ("core-established",
     dict(chain="input", action="accept", state_match="established,related"),
     "input ct state established,related accept"),
    ("core-forward-out",
     dict(chain="forward", action="accept", out_iface="wg_main", state_match="established,related"),
     'forward oifname "wg_main" ct state established,related accept'),
    ("five-matches",
     dict(chain="forward", action="accept", in_iface="wg0", out_iface="eth0",
          source="10.0.0.0/24", destination="10.0.1.5", proto="tcp", dport=8080,
          state_match="new", comment="five matches"),
     'forward iifname "wg0" oifname "eth0" ip saddr 10.0.0.0/24 ip daddr 10.0.1.5 '
     'tcp dport 8080 ct state new accept comment "five matches"'),
    ("dnat-v4",
     dict(chain="prerouting", action="dnat to 10.0.0.5:443", in_iface="eth0",
          destination="192.0.2.1", proto="tcp", dport=8443),
     'prerouting iifname "eth0" ip daddr 192.0.2.1 tcp dport 8443 dnat ip to 10.0.0.5:443'),
    ("dnat-v6",
     dict(chain="prerouting", action="dnat to [fd00::5]:443", family=10, in_iface="eth0",
          destination="2001:db8::1", proto="tcp", dport=8443),
     'prerouting iifname "eth0" ip6 daddr 2001:db8::1 tcp dport 8443 dnat ip6 to [fd00::5]:443'),
    ("reject-network-port",
     dict(chain="output", action="reject", destination="192.0.2.0/24", proto="tcp", dport=25),
     "output ip daddr 192.0.2.0/24 tcp dport 25 reject"),
    ("drop-v6-both-ends",
     dict(chain="forward", action="drop", family=10, source="fd00:1::/64",
          destination="fd00:2::/64", proto="udp", dport=53),
     "forward ip6 saddr fd00:1::/64 ip6 daddr fd00:2::/64 udp dport 53 drop"),
    ("comment-ascii",
     dict(chain="input", action="accept", proto="tcp", dport=22, comment="ssh from anywhere"),
     'input tcp dport 22 accept comment "ssh from anywhere"'),
    ("comment-turkish",
     dict(chain="input", action="accept", proto="tcp", dport=23, comment="ğüşİıçö kural"),
     'input tcp dport 23 accept comment "ğüşİıçö kural"'),
    ("comment-chinese",
     dict(chain="input", action="accept", proto="tcp", dport=24, comment="防火墙规则"),
     'input tcp dport 24 accept comment "防火墙规则"'),
    ("comment-emoji",
     dict(chain="input", action="accept", proto="tcp", dport=26, comment="🔥 rule"),
     'input tcp dport 26 accept comment "🔥 rule"'),
    ("comment-128-bytes",
     dict(chain="input", action="accept", proto="tcp", dport=27, comment="ğ" * 64),
     f'input tcp dport 27 accept comment "{"ğ" * 64}"'),
]
ORDERS = ["started-then-add", "added-then-start"]


def _bridge(bridge, order):
    """The group and the ledger; started now, or by _apply after the adds."""
    bridge.create_group("r2")
    ledger = oracle.Ledger(bridge)
    if order == "started-then-add":
        bridge.start()
    return ledger


def _apply(bridge, ledger, order):
    """For added-then-start: start() now, and inet reference after it."""
    if order == "added-then-start":
        bridge.start()
        ledger.started()


def _restart(bridge, ledger):
    bridge.stop()
    ledger.stopped()
    bridge.start()
    ledger.started()


@pytest.mark.parametrize("order", ORDERS)
@pytest.mark.parametrize("fields, rule", [c[1:] for c in CASES], ids=[c[0] for c in CASES])
def test_one_rule(bridge, db_path, meter, order, fields, rule):
    ledger = _bridge(bridge, order)
    rule_id = ledger.add("r2", rule, **fields)
    oracle.check(bridge, db_path, meter, ledger)
    _apply(bridge, ledger, order)
    oracle.check(bridge, db_path, meter, ledger)

    bridge.stop()
    ledger.stopped()
    oracle.check(bridge, db_path, meter, ledger)
    bridge.start()
    ledger.started()
    oracle.check(bridge, db_path, meter, ledger)

    ledger.remove(rule_id)
    oracle.check(bridge, db_path, meter, ledger)


@pytest.mark.parametrize("order", ORDERS)
def test_every_rule_in_one_table(bridge, db_path, meter, order):
    """All cases one after another, a restart, then removed odd positions
    first, then even ones."""
    ledger = _bridge(bridge, order)
    ids = []
    for _, fields, rule in CASES:
        ids.append(ledger.add("r2", rule, **fields))
        oracle.check(bridge, db_path, meter, ledger)
    _apply(bridge, ledger, order)
    oracle.check(bridge, db_path, meter, ledger)
    _restart(bridge, ledger)
    oracle.check(bridge, db_path, meter, ledger)

    for rule_id in ids[1::2] + ids[::2]:
        ledger.remove(rule_id)
        oracle.check(bridge, db_path, meter, ledger)


def test_field_order_is_the_bridges(bridge, db_path, meter):
    """nft keeps the matches in the order they are written: the same
    matches in another order are another rule to it."""
    ledger = _bridge(bridge, "started-then-add")
    fields = dict(chain="input", action="accept", in_iface="wg0", source="10.0.0.0/24",
                  proto="tcp", dport=443)
    ledger.add("r2", 'input iifname "wg0" ip saddr 10.0.0.0/24 tcp dport 443 accept', **fields)
    oracle.check(bridge, db_path, meter, ledger)
    bridge.add_firewall_rule("r2", **fields)
    oracle.reference_add('input tcp dport 443 ip saddr 10.0.0.0/24 iifname "wg0" accept')
    with pytest.raises(AssertionError, match="input differs"):
        oracle.assert_same_rules(oracle.read_table(PHANTOM), oracle.read_table(REFERENCE))


def test_the_listing_loads_back(bridge, db_path, meter):
    """The table's text listing, with every case's comment in it, loads
    back with `nft -f` into the same table."""
    ledger = _bridge(bridge, "started-then-add")
    for _, fields, rule in CASES:
        ledger.add("r2", rule, **fields)
    listing = oracle.run([oracle.NFT, f"list table inet {PHANTOM}"])
    before = oracle.read_table(PHANTOM)
    oracle.delete_table(PHANTOM)
    loaded = subprocess.run([oracle.NFT, "-f", "-"], input=listing, capture_output=True,
                            text=True, check=False)
    assert loaded.returncode == 0, loaded.stderr
    assert oracle.read_table(PHANTOM).rules == before.rules


def test_a_quoted_comment_does_not_load_back():
    """nft takes a double quote and a backslash in a JSON comment, and its
    text listing of that rule then fails `nft -f`."""
    table = "r2quote"
    try:
        oracle.nft(f"add table inet {table}")
        oracle.nft(f"add chain inet {table} c")
        oracle.run([oracle.NFT, "-j", json.dumps({"nftables": [{"add": {"rule": {
            "family": "inet", "table": table, "chain": "c",
            "expr": [{"accept": None}], "comment": 'a"b\\c'}}}]})])
        listing = oracle.run([oracle.NFT, f"list table inet {table}"])
        oracle.delete_table(table)
        loaded = subprocess.run([oracle.NFT, "-f", "-"], input=listing, capture_output=True,
                                text=True, check=False)
        assert loaded.returncode != 0, listing
    finally:
        oracle.delete_table(table)


@pytest.mark.parametrize("comment", ['say "hi"', "back\\slash", "two\nlines", "tab\there",
                                     "ğ" * 65, "a" * 129])
def test_comments_the_bridge_refuses(bridge, db_path, meter, comment):
    """A comment with a double quote, a backslash or a control character,
    or longer than 128 bytes, is refused before the database or nft."""
    ledger = _bridge(bridge, "started-then-add")
    with pytest.raises(InvalidParamError, match="rule.comment"):
        ledger.add("r2", "input accept", chain="input", action="accept", comment=comment)
    oracle.check(bridge, db_path, meter, ledger)
