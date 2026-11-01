"""
R4: routing rows through the bridge and through ip.

Drives: add_routing_rule for ensure, policy (from, from and to) and route
(a network, a host, default) rows, IPv4 and IPv6, in tables below and
above 255, named through the group's own ensure row or given as numbers;
the multihop shape of policy and route rows; started then added and
added then started; stop() and start(); disable_group and enable_group;
remove_routing_rule; delete_group; and a new FirewallBridge on the same
database while the kernel still holds the last one's rules. After every
step the database's routing rows are the kernel's policy rules and
routes (oracle.assert_routing_matches_db) and the meter is flat. Each
case's state, as `ip -N -j` prints it, equals the state its ip commands
below make by hand.

Does not show: routes through a gateway, other route types or metrics
(the bridge writes none); names given by another group or by the system
(each case names its own); packets. The priorities and tables are the
rule stage's own (oracle.RULE_PRIORITIES, oracle.ROUTE_TABLES).
"""

from __future__ import annotations

import pytest

from firewall_bridge import FirewallBridge

from e2e_tests.rules import oracle

# (id, add_routing_rule rows, the same state made with ip). A v4 default
# route of the bridge has universe scope, so its ip command says scope
# global; ip gives a device route link scope.
CASES = [
    ("policy-v4-from",
     [dict(rule_type="policy", from_network="10.40.0.0/24", table_name="150", priority=5001)],
     [["rule", "add", "from", "10.40.0.0/24", "lookup", "150", "priority", "5001"]]),
    ("policy-v4-from-to-main",
     [dict(rule_type="policy", from_network="10.40.0.0/24", to_network="10.41.0.0/24",
           table_name="main", priority=5002)],
     [["rule", "add", "from", "10.40.0.0/24", "to", "10.41.0.0/24", "lookup", "main",
       "priority", "5002"]]),
    ("policy-v6-from",
     [dict(rule_type="policy", family=10, from_network="fd00:40::/64", table_name="151",
           priority=5003)],
     [["-6", "rule", "add", "from", "fd00:40::/64", "lookup", "151", "priority", "5003"]]),
    ("policy-v6-from-to",
     [dict(rule_type="policy", family=10, from_network="fd00:40::/64",
           to_network="fd00:41::/64", table_name="151", priority=5004)],
     [["-6", "rule", "add", "from", "fd00:40::/64", "to", "fd00:41::/64", "lookup", "151",
       "priority", "5004"]]),
    ("policy-table-above-255",
     [dict(rule_type="policy", from_network="10.42.0.0/24", table_name="1000", priority=5005)],
     [["rule", "add", "from", "10.42.0.0/24", "lookup", "1000", "priority", "5005"]]),
    ("policy-named-by-the-group",
     [dict(rule_type="ensure", table_name="r4named", table_id=155),
      dict(rule_type="policy", from_network="10.42.0.0/24", table_name="r4named", priority=5006)],
     [["rule", "add", "from", "10.42.0.0/24", "lookup", "155", "priority", "5006"]]),
    ("route-v4-network",
     [dict(rule_type="route", destination="10.43.0.0/16", device="lo", table_name="150")],
     [["route", "add", "10.43.0.0/16", "dev", "lo", "table", "150", "proto", "static"]]),
    ("route-v4-host",
     [dict(rule_type="route", destination="10.43.0.1/32", device="lo", table_name="150")],
     [["route", "add", "10.43.0.1/32", "dev", "lo", "table", "150", "proto", "static"]]),
    ("route-v4-default",
     [dict(rule_type="route", destination="default", device="lo", table_name="1000")],
     [["route", "add", "default", "dev", "lo", "table", "1000", "proto", "static",
       "scope", "global"]]),
    ("route-v6-network",
     [dict(rule_type="route", family=10, destination="fd00:43::/64", device="lo",
           table_name="152")],
     [["-6", "route", "add", "fd00:43::/64", "dev", "lo", "table", "152", "proto", "static"]]),
    ("route-v6-default",
     [dict(rule_type="route", family=10, destination="default", device="lo", table_name="1001")],
     [["-6", "route", "add", "default", "dev", "lo", "table", "1001", "proto", "static"]]),
    ("route-named-by-the-group",
     [dict(rule_type="ensure", table_name="r4routes", table_id=156),
      dict(rule_type="route", destination="10.44.0.0/16", device="lo", table_name="r4routes")],
     [["route", "add", "10.44.0.0/16", "dev", "lo", "table", "156", "proto", "static"]]),
    ("multihop-v4",
     [dict(rule_type="ensure", table_name="r4mh", table_id=157),
      dict(rule_type="policy", from_network="10.45.0.0/24", to_network="10.45.0.0/24",
           table_name="main", priority=5007),
      dict(rule_type="policy", from_network="10.45.0.0/24", table_name="r4mh", priority=5008),
      dict(rule_type="route", destination="10.45.0.0/24", device="lo", table_name="r4mh"),
      dict(rule_type="route", destination="default", device="lo", table_name="r4mh")],
     [["rule", "add", "from", "10.45.0.0/24", "to", "10.45.0.0/24", "lookup", "main",
       "priority", "5007"],
      ["rule", "add", "from", "10.45.0.0/24", "lookup", "157", "priority", "5008"],
      ["route", "add", "10.45.0.0/24", "dev", "lo", "table", "157", "proto", "static"],
      ["route", "add", "default", "dev", "lo", "table", "157", "proto", "static",
       "scope", "global"]]),
    ("multihop-v6",
     [dict(rule_type="ensure", family=10, table_name="r4mh6", table_id=158),
      dict(rule_type="policy", family=10, from_network="fd00:45::/64", to_network="fd00:45::/64",
           table_name="main", priority=5009),
      dict(rule_type="policy", family=10, from_network="fd00:45::/64", table_name="r4mh6",
           priority=5010),
      dict(rule_type="route", family=10, destination="fd00:45::/64", device="lo",
           table_name="r4mh6"),
      dict(rule_type="route", family=10, destination="default", device="lo", table_name="r4mh6")],
     [["-6", "rule", "add", "from", "fd00:45::/64", "to", "fd00:45::/64", "lookup", "main",
       "priority", "5009"],
      ["-6", "rule", "add", "from", "fd00:45::/64", "lookup", "158", "priority", "5010"],
      ["-6", "route", "add", "fd00:45::/64", "dev", "lo", "table", "158", "proto", "static"],
      ["-6", "route", "add", "default", "dev", "lo", "table", "158", "proto", "static"]]),
]


@pytest.fixture(autouse=True)
def routing():
    oracle.clear_routing()
    yield
    oracle.clear_routing()


def _check(bridge, db_path, meter):
    oracle.check(bridge, db_path, meter)
    oracle.assert_routing_matches_db(db_path)


@pytest.mark.parametrize("order", ["started-then-add", "added-then-start"])
@pytest.mark.parametrize("rows, commands", [c[1:] for c in CASES], ids=[c[0] for c in CASES])
def test_one_case(bridge, db_path, meter, order, rows, commands):
    bridge.create_group("r4")
    if order == "started-then-add":
        bridge.start()
    for row in rows:
        bridge.add_routing_rule("r4", **row)
        _check(bridge, db_path, meter)
    if order == "added-then-start":
        bridge.start()
        _check(bridge, db_path, meter)
    made = oracle.routing_state()
    assert made != ([], {}), "the case made nothing"

    bridge.stop()
    _check(bridge, db_path, meter)
    assert oracle.routing_state() == ([], {})
    bridge.start()
    _check(bridge, db_path, meter)
    assert oracle.routing_state() == made

    bridge.delete_group("r4")
    _check(bridge, db_path, meter)
    assert oracle.routing_state() == ([], {})

    for command in commands:
        oracle.run([oracle.IP, *command])
    assert oracle.routing_state() == made


def _two_groups(bridge):
    """Two groups whose rows sit in the same tables."""
    bridge.create_group("a", priority=10)
    for row in CASES[-2][1]:
        bridge.add_routing_rule("a", **row)
    bridge.create_group("b", priority=20)
    ids = [bridge.add_routing_rule("b", **row) for row in
           (dict(rule_type="policy", from_network="10.46.0.0/24", table_name="150", priority=5011),
            dict(rule_type="route", destination="10.46.0.0/24", device="lo", table_name="150"),
            dict(rule_type="route", family=10, destination="fd00:46::/64", device="lo",
                 table_name="150"))]
    return ids


def test_groups_turned_off_and_on(bridge, db_path, meter):
    ids = _two_groups(bridge)
    bridge.start()
    _check(bridge, db_path, meter)
    for step in (lambda: bridge.disable_group("a"), lambda: bridge.enable_group("a"),
                 lambda: bridge.disable_group("b"), lambda: bridge.disable_group("a"),
                 lambda: bridge.enable_group("b"), lambda: bridge.enable_group("a"),
                 lambda: bridge.remove_routing_rule(ids[0]),
                 lambda: bridge.remove_routing_rule(ids[2]),
                 bridge.stop, bridge.start,
                 lambda: bridge.delete_group("b"), lambda: bridge.delete_group("a")):
        step()
        _check(bridge, db_path, meter)
    assert oracle.routing_state() == ([], {})


def test_a_new_bridge_finds_the_last_ones_routing(bridge, db_path, meter):
    """The first bridge's process ends without stop(): its policy rules and
    routes stay in the kernel; the new bridge's start() leaves one of each,
    not two."""
    _two_groups(bridge)
    bridge.start()
    left = oracle.routing_state()

    second = FirewallBridge(db_path)
    try:
        assert oracle.routing_state() == left
        second.start()
        _check(second, db_path, meter)
        assert oracle.routing_state() == left
    finally:
        second.close()


def test_two_groups_one_name_two_ids(bridge, db_path, meter):
    """Two groups name a table alike with ids of their own: each group's
    routes go to its own id, and deleting one leaves the other's."""
    bridge.create_group("x", priority=10)
    bridge.add_routing_rule("x", "ensure", table_name="r4shared", table_id=153)
    bridge.add_routing_rule("x", "route", destination="10.47.0.0/16", device="lo",
                            table_name="r4shared")
    bridge.create_group("y", priority=20)
    bridge.add_routing_rule("y", "ensure", table_name="r4shared", table_id=154)
    bridge.add_routing_rule("y", "route", destination="10.48.0.0/16", device="lo",
                            table_name="r4shared")
    bridge.start()
    _check(bridge, db_path, meter)
    assert sorted(oracle.routing_state()[1]) == [153, 154]
    bridge.stop()
    bridge.start()
    _check(bridge, db_path, meter)
    bridge.delete_group("x")
    _check(bridge, db_path, meter)
    assert list(oracle.routing_state()[1]) == [154]


# ── The routing check, before it judges the bridge ───────────────

def _one_policy_and_route(bridge):
    bridge.create_group("r4")
    bridge.add_routing_rule("r4", "ensure", table_name="r4check", table_id=159)
    bridge.add_routing_rule("r4", "policy", from_network="10.49.0.0/24", table_name="r4check",
                            priority=5012)
    bridge.add_routing_rule("r4", "route", destination="10.49.0.0/24", device="lo",
                            table_name="r4check")
    bridge.start()


def test_the_check_finds_a_policy_rule_from_outside(bridge, db_path):
    _one_policy_and_route(bridge)
    oracle.run([oracle.IP, "rule", "add", "from", "10.50.0.0/24", "lookup", "159",
                "priority", "5013"])
    with pytest.raises(AssertionError, match="policy rules differ"):
        oracle.assert_routing_matches_db(db_path)


def test_the_check_finds_a_route_gone(bridge, db_path):
    _one_policy_and_route(bridge)
    oracle.run([oracle.IP, "route", "del", "10.49.0.0/24", "dev", "lo", "table", "159"])
    with pytest.raises(AssertionError, match="routes differ"):
        oracle.assert_routing_matches_db(db_path)


def test_the_check_finds_a_table_name_gone(bridge, db_path):
    _one_policy_and_route(bridge)
    lines = open(oracle.DROP_IN).read().splitlines()
    with open(oracle.DROP_IN, "w") as f:
        f.write("".join(f"{line}\n" for line in lines if line != "159 r4check"))
    with pytest.raises(AssertionError, match="159 r4check: .* holds neither its id nor its name"):
        oracle.assert_routing_matches_db(db_path)
