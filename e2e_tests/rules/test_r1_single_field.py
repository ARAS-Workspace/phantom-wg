"""
R1: rules with one match field, through the bridge and through nft.

Drives: FirewallBridge.add_firewall_rule and remove_firewall_rule on a
started bridge with one group, for each match (iifname, oifname, ip and
ip6 saddr and daddr, tcp and udp dport, ct state), each action (accept,
drop, reject, masquerade, dnat) and each of the five chains, then stop().
Each case's nft rule is written out below by hand. After every step the
three invariants of oracle.check hold.

Does not show: rules with several fields, comments and field order (R2);
groups, enable/disable, stop/start with rules in place (R3); routing (R4);
presets (R5); size (R6); changes made from outside the bridge (R7);
refused input (R8). No packet is sent: a rule's presence in the table says
nothing about the traffic it matches.
"""

from __future__ import annotations

import pytest

from e2e_tests.rules import oracle

# (id, add_firewall_rule fields, the same rule as nft takes it)
CASES = [
    ("input-accept",
     dict(chain="input", action="accept"),
     "input accept"),
    ("iifname",
     dict(chain="input", action="accept", in_iface="wg0"),
     'input iifname "wg0" accept'),
    ("oifname",
     dict(chain="output", action="accept", out_iface="eth0"),
     'output oifname "eth0" accept'),
    ("saddr-v4",
     dict(chain="input", action="accept", source="10.0.0.0/24"),
     "input ip saddr 10.0.0.0/24 accept"),
    ("saddr-v6",
     dict(chain="input", action="accept", family=10, source="fd00:1::/64"),
     "input ip6 saddr fd00:1::/64 accept"),
    ("daddr-v4",
     dict(chain="output", action="accept", destination="192.0.2.1"),
     "output ip daddr 192.0.2.1 accept"),
    ("daddr-v6",
     dict(chain="output", action="accept", family=10, destination="2001:db8::1"),
     "output ip6 daddr 2001:db8::1 accept"),
    ("tcp-dport",
     dict(chain="input", action="accept", proto="tcp", dport=443),
     "input tcp dport 443 accept"),
    ("udp-dport",
     dict(chain="input", action="accept", proto="udp", dport=51820),
     "input udp dport 51820 accept"),
    ("ct-state",
     dict(chain="forward", action="accept", state_match="established"),
     "forward ct state established accept"),
    ("ct-states",
     dict(chain="forward", action="accept", state_match="established,related"),
     "forward ct state established,related accept"),
    ("ct-state-upper-case",
     dict(chain="forward", action="accept", state_match="NEW"),
     "forward ct state new accept"),
    ("forward-drop",
     dict(chain="forward", action="drop", in_iface="wg1"),
     'forward iifname "wg1" drop'),
    ("output-drop-v6",
     dict(chain="output", action="drop", family=10, destination="fd00:9::/48"),
     "output ip6 daddr fd00:9::/48 drop"),
    ("reject",
     dict(chain="input", action="reject", proto="tcp", dport=25),
     "input tcp dport 25 reject"),
    ("reject-v6",
     dict(chain="input", action="reject", family=10, source="fd00:2::/64"),
     "input ip6 saddr fd00:2::/64 reject"),
    ("masquerade",
     dict(chain="postrouting", action="masquerade", out_iface="eth0"),
     'postrouting oifname "eth0" masquerade'),
    ("masquerade-v6",
     dict(chain="postrouting", action="masquerade", family=10, source="fd00:10:1::/64"),
     "postrouting ip6 saddr fd00:10:1::/64 masquerade"),
    ("dnat-port",
     dict(chain="prerouting", action="dnat to 192.0.2.10:443", proto="tcp", dport=8443),
     "prerouting tcp dport 8443 dnat ip to 192.0.2.10:443"),
    ("dnat-port-v6",
     dict(chain="prerouting", action="dnat to [2001:db8::10]:443", family=10,
          proto="tcp", dport=8443),
     "prerouting tcp dport 8443 dnat ip6 to [2001:db8::10]:443"),
    ("dnat-address",
     dict(chain="prerouting", action="dnat to 192.0.2.10", destination="192.0.2.1"),
     "prerouting ip daddr 192.0.2.1 dnat ip to 192.0.2.10"),
    ("prerouting-accept",
     dict(chain="prerouting", action="accept", in_iface="wg0"),
     'prerouting iifname "wg0" accept'),
    ("postrouting-accept",
     dict(chain="postrouting", action="accept"),
     "postrouting accept"),
]


def _started(bridge):
    bridge.create_group("r1")
    bridge.start()
    return oracle.Ledger(bridge)


@pytest.mark.parametrize("fields, rule", [c[1:] for c in CASES], ids=[c[0] for c in CASES])
def test_one_rule(bridge, db_path, meter, fields, rule):
    ledger = _started(bridge)
    oracle.check(bridge, db_path, meter, ledger)

    rule_id = ledger.add("r1", rule, **fields)
    oracle.check(bridge, db_path, meter, ledger)

    ledger.remove(rule_id)
    oracle.check(bridge, db_path, meter, ledger)

    bridge.stop()
    oracle.check(bridge, db_path, meter, ledger)


def test_every_rule_in_one_table(bridge, db_path, meter):
    """All cases added one after another, then removed odd positions
    first, then even ones."""
    ledger = _started(bridge)
    ids = []
    for _, fields, rule in CASES:
        ids.append(ledger.add("r1", rule, **fields))
        oracle.check(bridge, db_path, meter, ledger)

    for rule_id in ids[1::2] + ids[::2]:
        ledger.remove(rule_id)
        oracle.check(bridge, db_path, meter, ledger)

    bridge.stop()
    oracle.check(bridge, db_path, meter, ledger)
