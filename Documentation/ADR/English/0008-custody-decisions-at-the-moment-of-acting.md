# ADR-0008 — Custody Decisions Are Made at the Moment of Acting

## Status

Accepted — 2026-08-15

This is an **extension record**: it narrows an accepted record through the mechanism [ADR-0001 Item 5](0001-architectural-decision-records.md#decision) describes. The record it extends is ADR-0005. It gathers three hardenings of the custody path; none reverses a decision. All three share a single premise: a decision about a payload is taken on what the stores say at the moment of acting, not on what an earlier answer said.

- Fix: the duplicate purge drops orphans only, and a restore proves, marks and re-checks each candidate at the moment it mints ([365bc45](https://github.com/ARAS-Workspace/phantom-wg/commit/365bc4580221eb06a848d3e7c8636f97620517d2))

- Fix: a vault the harness can make answer one thing in bulk and another per id, and seven custody steps that spend it ([27e754a](https://github.com/ARAS-Workspace/phantom-wg/commit/27e754ae0cb9fc2d7ca2f959c62e43307b56b398))

## Context

**Record extended:** [ADR-0005 System Keychain Tunnel Vault](0005-system-keychain-tunnel-vault.md); the relevant sections are [Decision](0005-system-keychain-tunnel-vault.md#decision) and [Edge Cases](0005-system-keychain-tunnel-vault.md#edge-cases).

**Source:** `Phantom-WG-MacOS/Infrastructure/Tunnel/TunnelsManager.swift`, commits [`365bc45`](https://github.com/ARAS-Workspace/phantom-wg/commit/365bc4580221eb06a848d3e7c8636f97620517d2) and [`27e754a`](https://github.com/ARAS-Workspace/phantom-wg/commit/27e754ae0cb9fc2d7ca2f959c62e43307b56b398).

This document does not restate ADR-0005. It narrows the binding of three of its items and adds a row to its table.

### Narrowed Items

| ADR-0005 | What the item bound until now | With this decision | Source |
| --- | --- | --- | --- |
| **Item 12** Name uniqueness is enforced at write time | The vault write drops **every other** payload record claiming the same name; that is the single path a name collision could be born through, and it is closed | The write drops **orphans only**: a record whose identity is on the list, or marked in flight, is kept and the write proceeds. | `purgeVaultDuplicates` |
| **Item 8** Reconcile carries three duties and converges on the vault | A payload with no system entry is recreated; the evidence is the bulk read taken at the top of the pass. | Each candidate is re-read by id **at the moment it would mint**, and the entry is created **from the freshly read body**. The two list tests are taken immediately before the mint, synchronously. A vault that does not answer stops the pass from minting anything further. | `reconcileFromVault` |
| **Item 11** Ordering guarantees (the in-flight mark) | The mark has one writer (the add) and one reader (the restore) | The mark has a **second writer**: the restore itself, which marks the whole candidate set rather than one candidate at a time. And a **second reader**: the deduplication | `creatingIds` |

The reason behind all three, in one sentence: the guards read the LIST's names while the deduplication reads the VAULT's names, and the two stores part company on their own after a rolled-back write; once they have, a live tunnel's record looks like an orphan and a deleted payload looks like a candidate worth restoring.

### To Be Carried Into the Edge Cases Table

The following belong to ADR-0005's [Edge Cases](0005-system-keychain-tunnel-vault.md#edge-cases) table. The table is not edited; with this decision it now reads as below.

**Two rows change:**

| Existing row | What it held until now | With this decision |
| --- | --- | --- |
| A payload's name collides with a listed tunnel | "The last defence of a scene that structurally cannot be staged" | The scene can be staged, so the defence is live rather than vestigial: because a record can now be spared, the vault can hold two records claiming one name, and the skip behaviour is what keeps that state inert. |
| **TunnelVault** is unanswering at the moment of import | "A name collision cannot be born" | The import is still refused, but this is no longer the only path: sparing a record can leave two records claiming one name as well. |

**Rows to add:**

| Situation | Behaviour | Assessment |
| --- | --- | --- |
| A write claims the name of a payload whose identity is listed, or being created | The record is kept and the write proceeds | The only copy of a live key is never deleted |
| A restore candidate's payload is deleted while the pass is running | That candidate is not minted | An entry whose secret is already gone cannot be born |
| The vault goes dark during a restore | Minting stops for the rest of the pass | Nothing is minted without evidence |
| A payload's body carries an id that contradicts the key it was read under | Refused as a custody anomaly | Not normalized, because nothing the app writes can produce it |

## Decision

A custody decision is taken on evidence that is current at the moment of the act, and a payload whose entry is on its way — or whose fate a pass in flight is deciding — is marked so the other path can see it. Concretely:

1. **The write-time deduplication deletes orphans only.** A record whose identity is on the list, or marked in flight, is kept. One case is out of scope by design: a tunnel whose entry exists but which the list is not currently holding. Covering it would put a system round-trip on every write, and that case belongs to the hidden-entry class.

2. **A restore proves each candidate by id at the moment it would mint it**, acts on that answer rather than on the snapshot, and creates the entry from the freshly read body; because the probe is itself a suspension, it reads the live list once more in the same breath as the mint. The read is a single attempt: the retrying variant would spend up to ~16.8s per candidate against a dark vault, all of it holding the reconcile lock. The projection realign leaves out every identity the pass reached the mint for — landed, the row was already written from the newest reading the pass has; not landed, the comparison would write a stale name over a fresh one the pass never got to claim.

3. **A reconcile pass marks its whole candidate set in flight**, from the line where candidacy is decided until the pass ends. Marking one at a time is not enough, because every candidate behind the one in hand is a payload with no list row for the length of the queue ahead of it — precisely the shape the deduplication reads as an orphan.

None of the three touches where secrets live, the ownership boundary, or the handshake condition. They change only what the two paths are permitted to do to a payload while the other one is mid-act.

## Consequences

- A same-name import can no longer delete the only copy of a live or arriving tunnel's key. This is the class the three hardenings exist for.
- A restore never mints an entry whose secret has already been deleted, so the invisible-and-undeletable entry can no longer be born on this path.
- The vault may hold two records claiming one name. Nothing downstream acts on the duplicate, and the user can see and undo the one case that reaches the list.
- One additional vault read per restore candidate; zero in the steady state, and a dark vault costs one timeout for the pass rather than one per candidate.
- One case stays open by design: a tunnel whose entry exists but which the list is not currently holding. It belongs to the same class as the hidden entry itself and is recorded with it.
- All three changes are restrictive at their core. No flow gains a new capability; the write path deletes less and the restore path mints less.

## Related Records

- [ADR-0005](0005-system-keychain-tunnel-vault.md) items 8, 11 and 12: narrowed in the table above.
- [ADR-0005](0005-system-keychain-tunnel-vault.md) items 6 and 9: the ownership boundary and the rule that neither silence nor a failing answer counts as proof; unchanged, and both load-bearing for this record. Item 9 names three outcomes for a read; the per-id probe here branches on four, the fourth being the present-but-unreadable payload that ADR-0005 reports in its edge-case table rather than in item 9.
- [ADR-0001](0001-architectural-decision-records.md) item 5: the mechanism by which this record exists; an accepted ADR is not edited for corrections, a narrowing record is opened instead.
- [ADR-0007](0007-activation-and-vault-hardening.md): the record that established this shape for hardening passes.
