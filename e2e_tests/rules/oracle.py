"""
Reads what the kernel holds and what the bridge's database says, and
compares them.

The bridge writes the inet phantom table; the tests write inet reference
with nft commands of their own. Both are read with `nft -j` and reduced to
what each chain is and what each rule matches and does, without handles
and table names, so the two compare rule for rule.

The three invariants:
  1. assert_same_rules        phantom and reference hold the same chains
                              and, in each chain, the same rules in order
  2. assert_db_matches_kernel the database's applied rules are the kernel's
                              rules, handle for handle, and each one is the
                              rule its reference counterpart is
  3. ProcessMeter             no child, no nft process, no new zombie;
                              descriptors and threads back at the start
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass

NFT = "/usr/sbin/nft"
IP = "/usr/sbin/ip"

PHANTOM = "phantom"
REFERENCE = "reference"

# The reference table's base chains.
REFERENCE_CHAINS = (
    "input { type filter hook input priority 0; policy accept; }",
    "output { type filter hook output priority 0; policy accept; }",
    "forward { type filter hook forward priority 0; policy accept; }",
    "prerouting { type nat hook prerouting priority -100; policy accept; }",
    "postrouting { type nat hook postrouting priority 100; policy accept; }",
)


# ── Programs ──────────────────────────────────────────────────────

def run(argv: list[str]) -> str:
    """Runs a program to completion; returns stdout, raises with stderr."""
    r = subprocess.run(argv, capture_output=True, text=True, check=False)
    if r.returncode != 0:
        raise RuntimeError(
            f"{' '.join(argv)} failed (rc={r.returncode}): {r.stderr.strip()}"
        )
    return r.stdout


def nft(cmd: str) -> str:
    """One nft command, passed as a single argument."""
    return run([NFT, cmd])


# ── nft tables ────────────────────────────────────────────────────

_RULE_IDENTITY = ("family", "table", "chain", "handle")
_CHAIN_IDENTITY = ("family", "table", "name", "handle")


@dataclass(frozen=True)
class Table:
    """One inet table as nft lists it: per chain, its spec, its rules
    without identity fields, and their handles in the same order."""

    chains: dict[str, dict]
    rules: dict[str, list[dict]]
    handles: dict[str, list[int]]

    def body(self, chain: str, handle: int) -> dict:
        """The rule `handle` in `chain`; KeyError if the chain has none."""
        try:
            return self.rules[chain][self.handles[chain].index(handle)]
        except (KeyError, ValueError):
            raise KeyError(f"no rule with handle {handle} in {chain}") from None


def normalize(listing: dict) -> Table:
    """`nft -j list table` output → Table. Objects other than the table,
    its chains and its rules raise ValueError."""
    chains: dict[str, dict] = {}
    rules: dict[str, list[dict]] = {}
    handles: dict[str, list[int]] = {}
    for item in listing["nftables"]:
        if "chain" in item:
            c = item["chain"]
            chains[c["name"]] = {k: v for k, v in c.items() if k not in _CHAIN_IDENTITY}
            rules.setdefault(c["name"], [])
            handles.setdefault(c["name"], [])
        elif "rule" in item:
            r = item["rule"]
            rules.setdefault(r["chain"], []).append(
                {k: v for k, v in r.items() if k not in _RULE_IDENTITY}
            )
            handles.setdefault(r["chain"], []).append(r["handle"])
        elif not item.keys() & {"metainfo", "table"}:
            raise ValueError(f"unexpected object in the listing: {item}")
    return Table(chains, rules, handles)


def read_table(name: str) -> Table:
    return normalize(json.loads(run([NFT, "-j", f"list table inet {name}"])))


def delete_table(name: str) -> None:
    """Deletes inet `name`; a missing table is not an error."""
    subprocess.run([NFT, f"delete table inet {name}"], capture_output=True, check=False)


def create_reference(chains: tuple[str, ...] = REFERENCE_CHAINS) -> None:
    """inet reference with `chains`, and one rule added and flushed, so its
    rule handles start one later than a new inet phantom's."""
    nft(f"add table inet {REFERENCE}")
    for chain in chains:
        nft(f"add chain inet {REFERENCE} {chain}")
    first = chains[0].split(" ", 1)[0]
    nft(f"add rule inet {REFERENCE} {first} accept")
    nft(f"flush chain inet {REFERENCE} {first}")


def reference_add(rule: str) -> int:
    """Appends `rule` ("<chain> <statement>") to inet reference; returns
    its handle, read back from the listing."""
    chain = rule.split(" ", 1)[0]
    nft(f"add rule inet {REFERENCE} {rule}")
    return read_table(REFERENCE).handles[chain][-1]


def reference_delete(chain: str, handle: int) -> None:
    nft(f"delete rule inet {REFERENCE} {chain} handle {handle}")


# ── ip rules and routes ───────────────────────────────────────────

def ip_rules(lowest: int, highest: int) -> list[dict]:
    """`ip -j rule show` for both families, the rules whose priority is
    in [lowest, highest], each with its family flag."""
    rules = []
    for family in ("-4", "-6"):
        for r in json.loads(run([IP, "-j", family, "rule", "show"])):
            if lowest <= r["priority"] <= highest:
                rules.append({"family": family, **r})
    return rules


def ip_routes(table: str) -> list[dict]:
    """`ip -j route show table` for both families, each route with its
    family flag. A table the kernel does not have reads as empty."""
    routes = []
    for family in ("-4", "-6"):
        r = subprocess.run(
            [IP, "-j", family, "route", "show", "table", table],
            capture_output=True, text=True, check=False,
        )
        if r.returncode != 0:
            if "FIB table does not exist" in r.stderr:
                continue
            raise RuntimeError(f"ip {family} route show table {table}: {r.stderr.strip()}")
        routes += [{"family": family, **route} for route in json.loads(r.stdout)]
    return routes


# ── Invariant 1: the two tables ───────────────────────────────────

def assert_same_rules(phantom: Table, reference: Table) -> None:
    assert phantom.chains == reference.chains, (
        f"chains differ\n  phantom   {phantom.chains}\n  reference {reference.chains}"
    )
    for chain in reference.chains:
        assert phantom.rules[chain] == reference.rules[chain], (
            f"{chain} differs\n"
            f"  phantom   {json.dumps(phantom.rules[chain])}\n"
            f"  reference {json.dumps(reference.rules[chain])}"
        )


# ── Invariant 2: database and kernel ──────────────────────────────

class Ledger:
    """The rules a test gave both tables: bridge rule id → the chain and
    handle of the same rule in inet reference."""

    def __init__(self, bridge) -> None:
        self.bridge = bridge
        self.reference: dict[int, tuple[str, int]] = {}

    def add(self, group: str, reference_rule: str, **fields) -> int:
        """add_firewall_rule(group, **fields) on the bridge, and
        `reference_rule` on inet reference; returns the bridge's rule id."""
        chain = fields["chain"]
        assert reference_rule.split(" ", 1)[0] == chain, (chain, reference_rule)
        rule_id = self.bridge.add_firewall_rule(group, **fields)
        self.reference[rule_id] = (chain, reference_add(reference_rule))
        return rule_id

    def remove(self, rule_id: int) -> None:
        self.bridge.remove_firewall_rule(rule_id)
        chain, handle = self.reference.pop(rule_id)
        reference_delete(chain, handle)


def assert_db_matches_kernel(bridge, phantom: Table, ledger: Ledger | None = None,
                             reference: Table | None = None) -> None:
    """With a ledger, also each applied rule against its reference rule;
    `reference` is read when not given."""
    state = bridge.get_state()
    enabled = {g.id for g in bridge.list_groups() if g.enabled}
    rows = bridge.list_firewall_rules()

    for row in rows:
        expected = state == "started" and row.group_id in enabled
        assert row.applied == expected, (
            f"rule {row.id}: applied={row.applied}, state={state}, "
            f"group enabled={row.group_id in enabled}"
        )
        assert (row.nft_handle > 0) == row.applied, (
            f"rule {row.id}: applied={row.applied} with handle {row.nft_handle}"
        )

    in_db = [(r.chain, r.nft_handle) for r in rows if r.applied]
    assert len(set(in_db)) == len(in_db), f"one handle on two rules: {sorted(in_db)}"
    in_kernel = {(chain, h) for chain, hs in phantom.handles.items() for h in hs}
    assert set(in_db) == in_kernel, (
        f"only in the database: {sorted(set(in_db) - in_kernel)}; "
        f"only in the kernel: {sorted(in_kernel - set(in_db))}"
    )

    if ledger is None:
        return
    if reference is None:
        reference = read_table(REFERENCE)
    assert {r.id for r in rows} == set(ledger.reference), (
        f"database rules {sorted(r.id for r in rows)}, "
        f"test's rules {sorted(ledger.reference)}"
    )
    for row in rows:
        if row.applied:
            chain, handle = ledger.reference[row.id]
            assert phantom.body(row.chain, row.nft_handle) == reference.body(chain, handle), (
                f"rule {row.id} (handle {row.nft_handle}) is not its reference rule\n"
                f"  phantom   {json.dumps(phantom.body(row.chain, row.nft_handle))}\n"
                f"  reference {json.dumps(reference.body(chain, handle))}"
            )


# ── Invariant 3: processes ────────────────────────────────────────

@dataclass(frozen=True)
class Sample:
    children: int  # processes whose parent is this one, in any state
    nft: int       # nft processes in the container
    zombies: int   # zombie processes in the container
    fds: int       # open file descriptors of this process
    threads: int   # threads of this process
    rss_kb: int    # resident memory of this process


def _processes():
    """(comm, state, ppid) of every process in /proc."""
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat") as f:
                stat = f.read()
        except OSError:
            continue
        comm = stat[stat.index("(") + 1:stat.rindex(")")]
        state, ppid = stat[stat.rindex(")") + 2:].split()[:2]
        yield comm, state, int(ppid)


def sample() -> Sample:
    me = os.getpid()
    procs = list(_processes())
    with open("/proc/self/status") as f:
        status = dict(line.split(":", 1) for line in f)
    return Sample(
        children=sum(1 for _, _, ppid in procs if ppid == me),
        nft=sum(1 for comm, _, _ in procs if comm == "nft"),
        zombies=sum(1 for _, state, _ in procs if state == "Z"),
        fds=len(os.listdir("/proc/self/fd")),
        threads=int(status["Threads"]),
        rss_kb=int(status["VmRSS"].split()[0]),
    )


class ProcessMeter:
    """Checks samples against the one taken when the meter was made, and
    keeps the highest resident memory seen."""

    def __init__(self) -> None:
        self.baseline = sample()
        self.peak_rss_kb = self.baseline.rss_kb

    def _check(self, resources: bool) -> Sample:
        now = sample()
        self.peak_rss_kb = max(self.peak_rss_kb, now.rss_kb)
        b = self.baseline
        failed = [message for ok, message in [
            (now.children == 0, f"{now.children} child process(es) of pytest"),
            (now.nft == 0, f"{now.nft} nft process(es) running"),
            (now.zombies <= b.zombies, f"{now.zombies} zombie(s), {b.zombies} at the start"),
        ] + ([
            (now.fds == b.fds, f"{now.fds} descriptors open, {b.fds} at the start"),
            (now.threads == b.threads, f"{now.threads} threads, {b.threads} at the start"),
        ] if resources else []) if not ok]
        assert not failed, "; ".join(failed)
        return now

    def check_processes(self) -> Sample:
        return self._check(resources=False)

    def check_resources(self) -> Sample:
        """check_processes, and descriptors and threads as at the start;
        for a moment when no bridge is open."""
        return self._check(resources=True)

    def report(self) -> str:
        return (f"rss {self.baseline.rss_kb} kB at the start, "
                f"{self.peak_rss_kb} kB at most")


# ── All three ─────────────────────────────────────────────────────

def check(bridge, meter: ProcessMeter, ledger: Ledger | None = None) -> Table:
    """The three invariants; returns inet phantom as read."""
    phantom = read_table(PHANTOM)
    reference = read_table(REFERENCE)
    assert_same_rules(phantom, reference)
    assert_db_matches_kernel(bridge, phantom, ledger, reference)
    meter.check_processes()
    return phantom
