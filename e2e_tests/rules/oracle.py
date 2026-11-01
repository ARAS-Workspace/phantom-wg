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
  2. assert_db_matches_kernel the database file's applied rules are the
                              kernel's rules, handle for handle, each one is
                              the rule its reference counterpart is, and the
                              bridge reports the file as it is
     assert_routing_matches_db the same for the routing rows, against
                              the policy rules and routes ip lists
  3. ProcessMeter            no child, no nft process, no new zombie;
                              descriptors and threads back at the start
"""

from __future__ import annotations

import ipaddress
import json
import os
import sqlite3
import subprocess
from dataclasses import dataclass

from firewall_bridge import presets

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
    """`ip -N -j rule show` for both families, the rules whose priority is
    in [lowest, highest], each with its family flag. Tables read as ids; a
    host's source or destination, which ip prints without its length,
    reads with it."""
    rules = []
    for family in ("-4", "-6"):
        host = 128 if family == "-6" else 32
        for r in json.loads(run([IP, "-N", "-j", family, "rule", "show"])):
            if lowest <= r["priority"] <= highest:
                for end in ("src", "dst"):
                    if end in r and r[end] != "all":
                        r.setdefault(f"{end}len", host)
                rules.append({"family": family, **r})
    return rules


def ip_routes(table: str) -> list[dict]:
    """`ip -N -j route show table` for both families, each route with its
    family flag. A table the kernel does not have reads as empty."""
    routes = []
    for family in ("-4", "-6"):
        r = subprocess.run(
            [IP, "-N", "-j", family, "route", "show", "table", table],
            capture_output=True, text=True, check=False,
        )
        if r.returncode != 0:
            if "FIB table does not exist" in r.stderr:
                continue
            raise RuntimeError(f"ip {family} route show table {table}: {r.stderr.strip()}")
        routes += [{"family": family, **route} for route in json.loads(r.stdout)]
    return routes


# The policy rule priorities and route tables the rule stage owns.
RULE_PRIORITIES = (5000, 5999)
ROUTE_TABLES = tuple(range(150, 160)) + tuple(range(1000, 1010))

_BUILTIN_TABLES = {"default": 253, "main": 254, "local": 255}

# The bridge's own file of table names.
DROP_IN = "/etc/iproute2/rt_tables.d/phantom.conf"


def routing_state() -> tuple[list[dict], dict[int, list[dict]]]:
    """The kernel's policy rules in RULE_PRIORITIES and the routes of each
    ROUTE_TABLES table that has any."""
    routes = {t: ip_routes(str(t)) for t in ROUTE_TABLES}
    return ip_rules(*RULE_PRIORITIES), {t: r for t, r in routes.items() if r}


def clear_routing() -> None:
    """Deletes the rule stage's policy rules and flushes its route tables."""
    for r in ip_rules(*RULE_PRIORITIES):
        subprocess.run([IP, r["family"], "rule", "del", "priority", str(r["priority"])],
                       capture_output=True, check=False)
    for family in ("-4", "-6"):
        for t in ROUTE_TABLES:
            subprocess.run([IP, family, "route", "flush", "table", str(t)],
                           capture_output=True, check=False)


def _ip_net(text: str) -> tuple[str, int]:
    net = ipaddress.ip_network(text, strict=False)
    return str(net.network_address), net.prefixlen


def _route_dst(text: str) -> str:
    """A route destination as `ip -j` prints it."""
    if text == "default":
        return text
    net = ipaddress.ip_network(text, strict=False)
    return str(net.network_address) if net.prefixlen == net.max_prefixlen else str(net)


def assert_routing_matches_db(db_path: str) -> None:
    """Invariant 2 for routing: the database file's applied policy and
    route rows are the kernel's policy rules in RULE_PRIORITIES and its
    routes in ROUTE_TABLES, no more and no fewer. DROP_IN holds no id or
    name twice, and for each applied ensure row a line with its id or its
    name that is one of the applied ensure rows. A row's table is the id
    of its group's ensure row for that name, else the name as a number or
    a built-in name."""
    db = sqlite3.connect(db_path)
    try:
        rows = db.execute(
            "SELECT id, group_id, rule_type, family, from_network, to_network, table_name, "
            "table_id, priority, destination, device, applied FROM routing_rules").fetchall()
    finally:
        db.close()
    ensures = {(g, name): tid for _, g, kind, _, _, _, name, tid, _, _, _, _ in rows
               if kind == "ensure"}

    def table(group_id: int, name: str) -> int:
        if (group_id, name) in ensures:
            return ensures[(group_id, name)]
        return _BUILTIN_TABLES[name] if name in _BUILTIN_TABLES else int(name)

    want_rules, want_routes = [], {}
    for _, g, kind, fam, frm, to, name, _, prio, dst, dev, applied in rows:
        if not applied:
            continue
        flag = "-6" if fam == 10 else "-4"
        if kind == "policy":
            rule = {"family": flag, "priority": prio}
            rule["src"], rule["srclen"] = _ip_net(frm)
            if to:
                rule["dst"], rule["dstlen"] = _ip_net(to)
            rule["table"] = str(table(g, name))
            want_rules.append(rule)
        elif kind == "route":
            want_routes.setdefault(table(g, name), []).append(
                {"family": flag, "dst": _route_dst(dst), "dev": dev})

    lines = open(DROP_IN).read().split() if os.path.exists(DROP_IN) else []
    named = list(zip(map(int, lines[0::2]), lines[1::2]))
    assert len({i for i, _ in named}) == len(named) == len({n for _, n in named}), (
        f"an id or a name twice in {DROP_IN}: {named}")
    ensured = {(tid, name) for _, _, kind, _, _, _, name, tid, _, _, _, applied in rows
               if kind == "ensure" and applied}
    for tid, name in ensured:
        line = [pair for pair in named if tid == pair[0] or name == pair[1]]
        assert line and line[0] in ensured, (
            f"{tid} {name}: {DROP_IN} holds {line or 'neither its id nor its name'}")

    rules, routes = routing_state()
    got_rules = [{k: v for k, v in r.items() if k in ("family", "priority", "src", "srclen",
                                                      "dst", "dstlen", "table")} for r in rules]
    key = lambda d: json.dumps(d, sort_keys=True)
    assert sorted(got_rules, key=key) == sorted(want_rules, key=key), (
        f"policy rules differ\n  kernel   {sorted(got_rules, key=key)}\n"
        f"  database {sorted(want_rules, key=key)}")
    got_routes = {t: sorted(({"family": r["family"], "dst": r["dst"], "dev": r["dev"]} for r in rs),
                            key=key) for t, rs in routes.items()}
    want_routes = {t: sorted(rs, key=key) for t, rs in want_routes.items()}
    assert got_routes == want_routes, (
        f"routes differ\n  kernel   {got_routes}\n  database {want_routes}")


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

@dataclass(frozen=True)
class Row:
    """A firewall_rules row, as far as the kernel is concerned."""

    id: int
    group_id: int
    chain: str
    applied: bool
    nft_handle: int


def read_db(path: str) -> tuple[str, set[int], list[Row]]:
    """(state, ids of the enabled groups, firewall rule rows ordered by
    group, position and id), read with sqlite3 from the file."""
    db = sqlite3.connect(path)
    try:
        state = db.execute("SELECT state FROM config WHERE id=1").fetchone()[0]
        enabled = {gid for (gid,) in db.execute("SELECT id FROM rule_groups WHERE enabled=1")}
        rows = [Row(i, g, c, bool(a), h) for i, g, c, a, h in db.execute(
            "SELECT id, group_id, chain, applied, nft_handle FROM firewall_rules "
            "ORDER BY group_id, position, id")]
    finally:
        db.close()
    return state, enabled, rows


class Ledger:
    """The rules a test gave the bridge and, with the same rule in nft's
    text syntax, inet reference: bridge rule id → the chain and handle of
    its reference rule, or None while the bridge has it unapplied."""

    def __init__(self, bridge) -> None:
        self.bridge = bridge
        self.reference: dict[int, tuple[str, int] | None] = {}
        self.texts: dict[int, str] = {}

    def add(self, group: str, reference_rule: str, **fields) -> int:
        """add_firewall_rule(group, **fields) on the bridge, then sync();
        returns the bridge's rule id."""
        chain = fields["chain"]
        assert reference_rule.split(" ", 1)[0] == chain, (chain, reference_rule)
        rule_id = self.bridge.add_firewall_rule(group, **fields)
        self.texts[rule_id] = reference_rule
        self.reference[rule_id] = None
        self.sync()
        return rule_id

    def remove(self, rule_id: int) -> None:
        self.bridge.remove_firewall_rule(rule_id)
        self.texts.pop(rule_id)
        self.reference.pop(rule_id)
        self.sync()

    def enable(self, group: str) -> None:
        self.bridge.enable_group(group)
        self.sync()

    def disable(self, group: str) -> None:
        self.bridge.disable_group(group)
        self.sync()

    def delete_group(self, group: str) -> None:
        gone = {r.id for r in self.bridge.list_firewall_rules(group)}
        self.bridge.delete_group(group)
        self._forget(gone)

    def apply_preset(self, preset, reference_rules: list[str]):
        """presets.apply_preset(bridge, preset), its rules paired in their
        order with reference_rules, then sync(); returns the group."""
        group = presets.apply_preset(self.bridge, preset)
        rows = self.bridge.list_firewall_rules(group.name)
        assert [r.chain for r in rows] == [t.split(" ", 1)[0] for t in reference_rules], (
            f"{group.name}: chains {[r.chain for r in rows]}, reference {reference_rules}")
        for row, text in zip(rows, reference_rules):
            self.texts[row.id] = text
            self.reference[row.id] = None
        self.sync()
        return group

    def remove_preset(self, name: str) -> None:
        gone = {r.id for r in self.bridge.list_firewall_rules(name)}
        presets.remove_preset(self.bridge, name)
        self._forget(gone)

    def _forget(self, gone: set[int]) -> None:
        for rule_id in gone & set(self.texts):
            self.texts.pop(rule_id)
            self.reference.pop(rule_id)
        self.sync()

    def stopped(self) -> None:
        """After bridge.stop()."""
        self.sync()

    def started(self) -> None:
        """After bridge.start()."""
        self.sync()

    def sync(self) -> None:
        """inet reference becomes the test's rules that the bridge holds
        applied: enabled groups by priority and id, each group's rules by
        position and id. Empty while the bridge is stopped."""
        nft(f"flush table inet {REFERENCE}")
        self.reference = dict.fromkeys(self.reference)
        if self.bridge.get_state() != "started":
            return
        for group in self.bridge.list_groups():
            if not group.enabled:
                continue
            for row in self.bridge.list_firewall_rules(group.name):
                if row.id in self.texts:
                    text = self.texts[row.id]
                    self.reference[row.id] = (text.split(" ", 1)[0], reference_add(text))


def assert_db_matches_kernel(bridge, db_path: str, phantom: Table, ledger: Ledger | None = None,
                             reference: Table | None = None) -> None:
    """The database file against the kernel, and the bridge's own report of
    the file against the file. With a ledger, also each applied rule
    against its reference rule; `reference` is read when not given."""
    state, enabled, rows = read_db(db_path)
    reported = [Row(r.id, r.group_id, r.chain, r.applied, r.nft_handle)
                for r in bridge.list_firewall_rules()]
    assert (bridge.get_state(), reported) == (state, rows), (
        f"the bridge reports {bridge.get_state()} {reported}\n"
        f"  the database holds {state} {rows}"
    )

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
        if not row.applied:
            continue
        assert ledger.reference[row.id] is not None, (
            f"rule {row.id} is applied, the test has it unapplied")
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

def check(bridge, db_path: str, meter: ProcessMeter, ledger: Ledger | None = None) -> Table:
    """The three invariants; returns inet phantom as read."""
    phantom = read_table(PHANTOM)
    reference = read_table(REFERENCE)
    assert_same_rules(phantom, reference)
    assert_db_matches_kernel(bridge, db_path, phantom, ledger, reference)
    meter.check_processes()
    return phantom
