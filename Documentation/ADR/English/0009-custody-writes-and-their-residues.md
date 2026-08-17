# ADR-0009 — Every Row Is Deleted In The Order That Leaves Its Own Residue Repairable

## Status

Accepted — 2026-08-17

This is an **extension record**: it narrows an accepted record by the route [ADR-0001 Item 5](0001-architectural-decision-records.md#decision) describes. The record it extends is ADR-0005, and it sits beside ADR-0008: that record bound custody READS to the moment of acting, this one does the same for custody WRITES. Neither reverses a decision; both rest on a single premise, that a decision about a store is made at the moment of acting.

- Fix: a removal now empties first the store whose loss its own row can survive ([e889681](https://github.com/ARAS-Workspace/phantom-wg/commit/e889681c4d24259977fa3b139f482e9b6a341626))

- Fix: the fake system list drops a provider whose entry a removal took, and five custody-write steps spend it ([b09ecbf](https://github.com/ARAS-Workspace/phantom-wg/commit/b09ecbf76cd11205ca8cfc91d6957eaed166691c))

- Fix: a teardown that takes the store is now obeyed by everything that would write to it ([065c902](https://github.com/ARAS-Workspace/phantom-wg/commit/065c902455933e02804b925bd81f85c782012d0e))

- Fix: the vault pass's teardown kit moves to its own file, and four new steps spend it ([3c6b90a](https://github.com/ARAS-Workspace/phantom-wg/commit/3c6b90aaf41926714fa1844214a09141a1851d92))

- Fix: a refused vault write now reaches the user as an answer rather than as a timeout ([d1392c0](https://github.com/ARAS-Workspace/phantom-wg/commit/d1392c04c804c3cd79fd4c542f42c5cb3cef9856))

- Fix: a removal the user gave up waiting on stops holding this app's whole self-heal shut ([24ab3d8](https://github.com/ARAS-Workspace/phantom-wg/commit/24ab3d86b044c7427fedd5935844d3c311bf44d4))

- Cila: a failed add's vault rollback reports the payload it left behind ([2c8bd9a](https://github.com/ARAS-Workspace/phantom-wg/commit/2c8bd9a5ea6a13f9a1a9d04a62e4a311fdce8641))

## Context

**Record extended:** [ADR-0005 System Keychain Tunnel Vault](0005-system-keychain-tunnel-vault.md); relevant sections [Decision](0005-system-keychain-tunnel-vault.md#decision) and [Edge Cases](0005-system-keychain-tunnel-vault.md#edge-cases).

**Source:** `Phantom-WG-MacOS/Infrastructure/Tunnel/TunnelsManager.swift`, `Phantom-WG-MacOS/Features/TunnelList/TunnelListView.swift`, `Phantom-WG-MacOS/Infrastructure/Tunnel/TunnelErrors.swift`, `Phantom-WG-MacOS/Infrastructure/Initialization/ExtensionGateController.swift`; commits [`e889681`](https://github.com/ARAS-Workspace/phantom-wg/commit/e889681c4d24259977fa3b139f482e9b6a341626), [`065c902`](https://github.com/ARAS-Workspace/phantom-wg/commit/065c902455933e02804b925bd81f85c782012d0e), [`d1392c0`](https://github.com/ARAS-Workspace/phantom-wg/commit/d1392c04c804c3cd79fd4c542f42c5cb3cef9856), [`24ab3d8`](https://github.com/ARAS-Workspace/phantom-wg/commit/24ab3d86b044c7427fedd5935844d3c311bf44d4) and [`2c8bd9a`](https://github.com/ARAS-Workspace/phantom-wg/commit/2c8bd9a5ea6a13f9a1a9d04a62e4a311fdce8641).

This document does not retell ADR-0005. It narrows the binding of two of its items, and makes three rows of its table read differently while adding five.

The reason for the narrowing is a single observation. ADR-0005 gave deletion a uniform order: vault first, then Network Extension. When that order is left half finished, what remains is a system entry with no secret, and the ownership boundary reads an entry with no secret as **another local user's**. The result is an entry the app cannot see, cannot delete, and which reconnects itself if its `on-demand` rule stayed `armed`. The reverse order does not produce that residue: a payload with no entry is the shape reconcile is defined to repair.

The reverse cannot be uniform either. `readAll` returns only payloads that decode, so reconcile can never put back a payload that does **not** decode; for that payload the entry is the only anchor. Taking the entry first on such a row locks the secret into the Keychain where the app can never name it again.

### Narrowed Items

| ADR-0005 | Bound until now | With this decision | Source |
| --- | --- | --- | --- |
| **Item 11** Ordering guarantees | "Deleting: vault first, then Network Extension; if the vault cannot be deleted, the operation is cancelled and the tunnel stays whole." The order is uniform and independent of the row. | The order is chosen per row, by the payload's verdict at that moment. A payload that decodes: **entry first**. A payload that does not: **payload first**, because the entry is the only anchor. A vault that does not answer: the deletion is **refused** and neither store is touched. The adding order is unchanged. | `entryGoesFirst(for:)`, `remove()` |
| **Item 8** Reconcile carries three duties and converges on the vault | The pass runs when its trigger arrives; there is no state that prevents it from running, and no such state is named. | The pass does **not** run while the app's own teardown holds the store, and that applies not only to a pass which has not started but to one **already running**: the `latch` is re-read at every point that writes. | `refreshSuspended`, `reload()`, `mintMissingEntries`, `realignDriftedProjections` |

A third binding is not an item in ADR-0005 but a table row, and it is made to read differently below: the difference between a write being **refused** and a write going **unanswered** existed only at the log level until now, and reached the user as one sentence.

### To Be Carried Into the Edge Cases Table

The following belong to ADR-0005's [Edge Cases](0005-system-keychain-tunnel-vault.md#edge-cases) table. The table is not edited; with this decision it now reads as below.

**Three changed rows:**

| Existing row | Verdict until now | With this decision |
| --- | --- | --- |
| The user deleted the tunnel from inside the app | "The **TunnelVault** record is deleted first and the tunnel does not come back" | The **Network Extension** entry is deleted first; the vault record follows and the tunnel still does not come back. Only a row carrying a payload that does not decode keeps the old order. |
| The **TunnelVault** record could not be deleted because the **System Extension** is unreachable | "The deletion is cancelled and the tunnel stays whole" | If the vault does **not answer**, the deletion never begins and the tunnel stays whole. If the vault says **no**, the entry is already gone; reconcile puts the remaining payload back, and the user reads the two as separate sentences. |
| The **System Extension** was removed and reinstalled and the **Network Extension** store was emptied | "All tunnels are restored from **TunnelVault**" | With one exception: if **the app itself** is running the removal, the restore does not run for the duration of that teardown. Putting back the entries a teardown has just emptied would produce identities the removal never saw. |

**Rows to add:**

| Case | Behaviour | Assessment |
| --- | --- | --- |
| The payload of the row being deleted does not decode | The payload is deleted first and the entry goes last | The entry is the only anchor an unrestorable secret has |
| The vault does not answer during a deletion | The deletion is refused and neither store is touched | No half state is produced |
| The entry deletion was refused | The row is handed back to the system's own reading and the tunnel stays whole, but with its `on-demand` rule `disarmed` | The price is named: the tunnel survives but is silently `disarmed` |
| The payload deletion failed and the entry is already gone | One pass is scheduled and the tunnel comes back | This is why the entry-first order exists |
| The app's own teardown has taken the store | The restore, the projection realignment and the queue hand-off all stop | No identity the removal never saw is created |
| The user never answers the removal approval | The wait ends on its own budget, the flow finishes and the `latch` comes down through the ordinary door | An abandoned removal cannot hold this app's whole self-heal shut for the life of the process |
| A failed add's vault rollback was refused or went unanswered | The payload left behind is reported | A repairable residue does not stay silent: the next reconcile may mint back the tunnel the add reported as failed |

## Decision

A custody write is ordered by the residue it leaves; that residue must be repairable, and where it cannot be, it must never be born. Concretely:

1. **The order is chosen per row.** Before the first destructive step the payload is read by id, and the verdict decides the order: a payload that decodes is deleted entry-first, one that does not is deleted payload-first, and a vault that does not answer makes the deletion refuse. The principle is not uniformity but this: **every row is deleted in the order that leaves its own residue repairable.** The read is patient because the deletion it replaced was patient; a momentary dark window does not turn into a refusal.

2. **The entry-first order carries a mandatory companion.** Reconcile's candidate filter must exclude identities that are being removed. Without that bar the order does not close the class, it **produces** it: the entry goes down, the system broadcasts a change, the pass reads the payload as an `orphan` and puts the entry back, and the payload deletion lands at exactly that moment. The bar is an inseparable part of the decision.

3. **The app's own teardown takes the store.** The removal flow raises a `latch` before the classification and lowers it on every exit of the flow. The `latch` bars not only a pass that has not started but one already running: every point that writes re-reads it. Only the paths that narrow are deliberately unbarred, because they produce nothing for a teardown to miss. Two doors lower the `latch` and both are named, but they are not equals. The first is the flow's own and it is the ordinary door. The second is recovery for a flow that never returns, and it is now a **backstop**: the case it was written for, a flow suspended on a system approval the user never answers, is bounded at the wait itself, so that flow leaves through the first door like every other exit. What is left for the second is what a per-request budget cannot reach, a `latch` raised by a task the system tore down some other way, leaving no exit to run at all. **Neither covers the other**, and that must not be misread: a teardown parked on a prompt leaves the gate sitting at ready without moving, so the second door's trigger never fires. Do not delete one believing it covers the other.

4. **A refusal and a silence do not reach the user in the same sentence.** When the vault says no, the state is exactly as it was and nothing was half written; when the vault does not answer, the write may even have landed and only its reply was lost. The two carry opposite information, and collapsing them into one sentence makes the user read the wrong one.

None of these touch where the secrets live, the ownership boundary, or the handshake condition. They change only the order a write takes, the bars it reads, and the sentence it ends with.

## Consequences

- The residue of a half-finished deletion now falls on the repairable side. The producer of the hidden-entry class that came from this path is closed.
- A row carrying a payload that does not decode keeps the old order as a named exemption. Because the rule is not uniform, reading it is not uniform either, and the exemption's reason is written beside the code.
- When the entry deletion is refused the tunnel survives but its `on-demand` rule ends up `disarmed`, because `remove()` lowers the rule before it touches the entry. This is a deliberate price and the user is not told about it today; telling them is a separate item.
- No self-heal runs while a removal is in progress. The price is that the list does not repair itself during the removal flow; the gain is that the removal does not report "clean" while leaving an entry in System Settings.
- The user may see two different error sentences. Both describe the failure of the same operation but suggest different things, and that distinction is intentional.
- An abandoned removal now ends on its own budget, so the `latch` does not stay raised for the life of the process. That does not make the second of this record's two doors unnecessary; it moves it from the ordinary path to a backstop.
- The principle is not specific to deletion: a failed add's vault rollback is a custody write too, and its residue is reported now. If that rollback is refused or goes unanswered, a payload is left with no entry, and the next reconcile may mint it back as the tunnel the add reported as failed. Being repairable, it is not forbidden to be born; being silent is.
- The same distinction reached the log surface: `remove()` and the uninstall sweep asserted that the rule stayed armed after a refused disarm save. No refusal establishes that, and both lines now say what the shared helper says.
- The deletion path has become one vault read more expensive. In the ordinary case that is a single round trip; the deletion path already spent at least one read before.

## Related Records

- [ADR-0005](0005-system-keychain-tunnel-vault.md) items 8 and 11: narrowed in the table above.
- [ADR-0005](0005-system-keychain-tunnel-vault.md) item 6: the ownership boundary. Unchanged, and it is what carries this record: the reason the entry-first order is preferred is that an entry with no secret is read by that boundary as another user's.
- [ADR-0008](0008-custody-decisions-at-the-moment-of-acting.md): the sibling record that bound custody reads to the moment of acting. The bar in item 2 of this record sits in the same filter as that record's in-flight mark.
- [ADR-0001](0001-architectural-decision-records.md) item 5: how this record comes to exist; an accepted ADR is not carved for a correction, a new record that narrows it is opened.
