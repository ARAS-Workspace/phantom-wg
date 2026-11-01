"""
R0: the oracle, before it judges the bridge.

Drives: normalize and assert_same_rules on one rule written through the
bridge and through nft, and on rules that differ from it in one respect;
assert_db_matches_kernel on a bridge whose kernel rules or database rows
are changed from outside it; ProcessMeter on a child, a zombie, an open
file and a thread made here; the ip readers on rules and routes written
with ip.

Does not show: that the bridge writes correct rules (R1 onward); the
zombie count on a zombie that is not pytest's own child. Resident memory
is printed at the end of the run, not checked. Apart from the first
test, each test changes one thing and asserts the oracle reports it.
"""

from __future__ import annotations

import shutil
import sqlite3
import subprocess
import threading
import time
from contextlib import contextmanager

import pytest

from e2e_tests.rules import oracle
from e2e_tests.rules.oracle import PHANTOM, REFERENCE

RULE = dict(chain="input", action="accept", proto="tcp", dport=443)
RULE_NFT = "input tcp dport 443 accept"


def _started(bridge):
    bridge.create_group("r0")
    bridge.start()
    return bridge


def _same_rules():
    oracle.assert_same_rules(oracle.read_table(PHANTOM), oracle.read_table(REFERENCE))


@contextmanager
def _db(path):
    """A second connection to the bridge's database, committed and closed
    on exit."""
    db = sqlite3.connect(path)
    try:
        with db:
            yield db
    finally:
        db.close()


def _wait_for_state(pid: int, state: str) -> None:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        with open(f"/proc/{pid}/stat") as f:
            if f.read().rsplit(")", 1)[1].split()[0] == state:
                return
        time.sleep(0.01)
    raise TimeoutError(f"process {pid} not in state {state}")


# ── Invariant 1 ───────────────────────────────────────────────────

def test_one_rule_two_ways_is_equal(bridge, meter):
    ledger = oracle.Ledger(_started(bridge))
    oracle.check(bridge, meter, ledger)
    ledger.add("r0", RULE_NFT, **RULE)
    oracle.check(bridge, meter, ledger)


# Each differs from RULE_NFT in one respect.
OTHERS = [
    ("port", "input tcp dport 444 accept"),
    ("protocol", "input udp dport 443 accept"),
    ("action", "input tcp dport 443 drop"),
    ("chain", "output tcp dport 443 accept"),
    ("comment", 'input tcp dport 443 accept comment "x"'),
    ("extra-match", 'input iifname "lo" tcp dport 443 accept'),
]


@pytest.mark.parametrize("rule", [o[1] for o in OTHERS], ids=[o[0] for o in OTHERS])
def test_a_rule_that_differs_is_found(bridge, rule):
    _started(bridge).add_firewall_rule("r0", **RULE)
    oracle.reference_add(rule)
    with pytest.raises(AssertionError):
        _same_rules()


def test_the_same_rules_in_another_order_are_found(bridge):
    _started(bridge).add_firewall_rule("r0", **RULE)
    bridge.add_firewall_rule("r0", "input", "drop")
    oracle.reference_add("input drop")
    oracle.reference_add(RULE_NFT)
    with pytest.raises(AssertionError):
        _same_rules()


def test_a_rule_too_many_is_found(bridge):
    _started(bridge).add_firewall_rule("r0", **RULE)
    oracle.reference_add(RULE_NFT)
    oracle.reference_add(RULE_NFT)
    with pytest.raises(AssertionError):
        _same_rules()


def test_a_chain_with_another_priority_is_found(bridge):
    _started(bridge)
    oracle.delete_table(REFERENCE)
    oracle.create_reference(tuple(
        c.replace("hook forward priority 0", "hook forward priority 1")
        for c in oracle.REFERENCE_CHAINS
    ))
    with pytest.raises(AssertionError, match="chains differ"):
        _same_rules()


def test_an_object_other_than_a_chain_or_rule_is_refused(bridge):
    _started(bridge)
    oracle.nft(f"add set inet {PHANTOM} s {{ type ipv4_addr; }}")
    with pytest.raises(ValueError, match="unexpected object"):
        oracle.read_table(PHANTOM)


# ── Invariant 2 ───────────────────────────────────────────────────

def test_a_rule_gone_from_the_kernel_is_found(bridge):
    _started(bridge).add_firewall_rule("r0", **RULE)
    handle = bridge.list_firewall_rules()[0].nft_handle
    oracle.nft(f"delete rule inet {PHANTOM} input handle {handle}")
    with pytest.raises(AssertionError, match="only in the database"):
        oracle.assert_db_matches_kernel(bridge, oracle.read_table(PHANTOM))


def test_a_rule_the_database_does_not_have_is_found(bridge):
    _started(bridge)
    oracle.nft(f"add rule inet {PHANTOM} {RULE_NFT}")
    with pytest.raises(AssertionError, match="only in the kernel"):
        oracle.assert_db_matches_kernel(bridge, oracle.read_table(PHANTOM))


def test_a_rule_left_unapplied_is_found(bridge, db_path):
    _started(bridge).add_firewall_rule("r0", **RULE)
    with _db(db_path) as db:
        db.execute("UPDATE firewall_rules SET applied=0, nft_handle=0")
    with pytest.raises(AssertionError, match="applied=False"):
        oracle.assert_db_matches_kernel(bridge, oracle.read_table(PHANTOM))


def test_a_rule_applied_while_stopped_is_found(bridge, db_path):
    _started(bridge).add_firewall_rule("r0", **RULE)
    with _db(db_path) as db:
        db.execute("UPDATE config SET state='stopped'")
    with pytest.raises(AssertionError, match="state=stopped"):
        oracle.assert_db_matches_kernel(bridge, oracle.read_table(PHANTOM))


def test_two_rules_with_swapped_handles_are_found(bridge, meter, db_path):
    ledger = oracle.Ledger(_started(bridge))
    first = ledger.add("r0", RULE_NFT, **RULE)
    second = ledger.add("r0", "input drop", chain="input", action="drop")
    oracle.check(bridge, meter, ledger)
    with _db(db_path) as db:
        (h1,), (h2,) = db.execute(
            "SELECT nft_handle FROM firewall_rules WHERE id IN (?, ?) ORDER BY id",
            (first, second),
        ).fetchall()
        db.execute("UPDATE firewall_rules SET nft_handle=? WHERE id=?", (h2, first))
        db.execute("UPDATE firewall_rules SET nft_handle=? WHERE id=?", (h1, second))
    phantom = oracle.read_table(PHANTOM)
    oracle.assert_db_matches_kernel(bridge, phantom)
    with pytest.raises(AssertionError, match="is not its reference rule"):
        oracle.assert_db_matches_kernel(bridge, phantom, ledger)


def test_a_database_row_the_test_did_not_make_is_found(bridge):
    ledger = oracle.Ledger(_started(bridge))
    ledger.add("r0", RULE_NFT, **RULE)
    bridge.add_firewall_rule("r0", "input", "drop")
    oracle.reference_add("input drop")
    with pytest.raises(AssertionError, match="test's rules"):
        oracle.assert_db_matches_kernel(bridge, oracle.read_table(PHANTOM), ledger)


# ── Invariant 3 ───────────────────────────────────────────────────

def test_a_running_child_is_found(meter):
    child = subprocess.Popen(["sleep", "30"])
    try:
        with pytest.raises(AssertionError, match="child process"):
            meter.check_processes()
    finally:
        child.kill()
        child.wait()
    meter.check_resources()


def test_a_zombie_child_is_found(meter):
    child = subprocess.Popen(["true"])
    try:
        _wait_for_state(child.pid, "Z")
        with pytest.raises(AssertionError, match="zombie"):
            meter.check_processes()
    finally:
        child.wait()
    meter.check_resources()


def test_a_running_nft_is_found(meter, tmp_path):
    fake = tmp_path / "nft"
    shutil.copy("/bin/sleep", fake)
    child = subprocess.Popen([str(fake), "30"])
    _wait_for_state(child.pid, "S")
    try:
        with pytest.raises(AssertionError, match="nft process"):
            meter.check_processes()
    finally:
        child.kill()
        child.wait()
    meter.check_resources()


def test_an_open_descriptor_is_found(meter, tmp_path):
    with open(tmp_path / "f", "w"):
        with pytest.raises(AssertionError, match="descriptors open"):
            meter.check_resources()
    meter.check_resources()


def test_a_thread_is_found(meter):
    stop = threading.Event()
    thread = threading.Thread(target=stop.wait)
    thread.start()
    try:
        with pytest.raises(AssertionError, match="threads"):
            meter.check_resources()
    finally:
        stop.set()
        thread.join()
    meter.check_resources()


# ── ip readers ────────────────────────────────────────────────────

@pytest.fixture
def ip_cleanup():
    yield
    for r in oracle.ip_rules(5000, 5999):
        subprocess.run([oracle.IP, r["family"], "rule", "del", "priority", str(r["priority"])],
                       check=False)
    for family in ("-4", "-6"):
        subprocess.run([oracle.IP, family, "route", "flush", "table", "150"],
                       capture_output=True, check=False)


def test_ip_rule_two_spellings_read_the_same(ip_cleanup):
    oracle.run([oracle.IP, "rule", "add", "from", "10.0.1.0/24", "lookup", "150", "pref", "5001"])
    first = oracle.ip_rules(5000, 5999)
    oracle.run([oracle.IP, "rule", "del", "pref", "5001"])
    oracle.run([oracle.IP, "rule", "add", "from", "10.0.1.0/24", "table", "150", "priority", "5001"])
    assert oracle.ip_rules(5000, 5999) == first
    assert first == [{"family": "-4", "priority": 5001, "src": "10.0.1.0", "srclen": 24,
                      "table": "150"}]


def test_ip_rule_reader_keeps_to_its_range(ip_cleanup):
    oracle.run([oracle.IP, "-6", "rule", "add", "from", "fd00:1::/64", "table", "150",
                "priority", "5999"])
    oracle.run([oracle.IP, "rule", "add", "from", "10.0.1.0/25", "table", "150",
                "priority", "6000"])
    try:
        assert [r["priority"] for r in oracle.ip_rules(5000, 5999)] == [5999]
        assert oracle.ip_rules(5000, 5999)[0]["family"] == "-6"
    finally:
        oracle.run([oracle.IP, "rule", "del", "priority", "6000"])


def test_ip_routes_reader(ip_cleanup):
    assert oracle.ip_routes("150") == []
    oracle.run([oracle.IP, "route", "add", "10.5.0.0/16", "dev", "lo", "table", "150"])
    oracle.run([oracle.IP, "-6", "route", "add", "fd00:5::/64", "dev", "lo", "table", "150"])
    routes = oracle.ip_routes("150")
    assert [(r["family"], r["dst"], r["dev"]) for r in routes] == [
        ("-4", "10.5.0.0/16", "lo"), ("-6", "fd00:5::/64", "lo"),
    ]
