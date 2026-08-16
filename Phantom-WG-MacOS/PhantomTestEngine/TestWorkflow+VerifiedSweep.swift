#if DEBUG
import Foundation

// MARK: - The verified-sweep kit: three-valued reads, re-read-verified
// deletes and entry removals, the fresh-list probe, and the two repair
// arms built on them.
//
// On the BASE because every workflow that plants something owes the
// same honesty when it cleans up, and until this move each of them
// answered that question its own way — some by asking the vault, some
// by reading the manager's list, some by collapsing a three-valued
// answer into a Bool. The mirror in particular cannot carry a cleanup
// verdict: a payload-less entry is filed as another local user's and
// disappears from it while still sitting in the system store, so "not
// in the list" and "gone" are different facts.
//
// One rule runs through every arm: a cleanup that cannot VERIFY what it
// did reports residue rather than success, and no arm claims a state it
// did not observe.
//
// Two members did NOT come along, and neither is an oversight.
// `sweepThrowaways` reads the owning workflow's own planted ledgers;
// `sweepCorruptionBase` carries a doctrine that holds for exactly one
// base — a deliberately corrupt payload, which `readAll` never returns
// and therefore no restore can ever repair, which is why THAT arm may
// take the entry last while a decodable row must not. Promoting either
// would hand other workflows a tool whose reasoning does not apply to
// them.
extension TestWorkflow {
    /// One vault read, kept three-valued. `.unreachable` is neither
    /// presence nor absence, and the nets below decide differently on
    /// each: collapsing it into "present" let their arms print
    /// verified-sounding verdicts — "still present", "swept" — over a
    /// reading that verified nothing.
    enum PayloadReading { case present, missing, unreachable }

    /// Three attempts, spaced: waking the vault extension usually
    /// costs the first one, and every sweep decision downstream rides
    /// this answer — a single lost 5s race must not convert a
    /// self-healing teardown into do-nothing residue. `.present` is
    /// presence only, decodable and corrupt bytes alike, which is why
    /// no arm below calls what it swept "corrupt": presence was
    /// observed, the bytes' nature was not.
    func readPayloadState(_ id: UUID) async -> PayloadReading {
        switch await vault.read(id: id, attempts: 3) {
        case .missing: return .missing
        case .unreachable: return .unreachable
        default: return .present
        }
    }

    /// How a sweep's outcome is decided. NEITHER non-done delete
    /// answer proves presence — a refusal can be the keychain door
    /// failing ("could not tell whose it is") or a slot that is not
    /// ours, and silence can be a landed delete with its reply lost —
    /// so BOTH are followed by one re-read, and each verdict claims
    /// exactly what was observed.
    enum SweepVerdict { case swept, sweptOnReread, stillPresent, unverified }

    func verifiedDelete(_ id: UUID) async -> SweepVerdict {
        switch await vault.delete(id: id, attempts: 3) {
        case .done:
            return .swept
        case .refused, .unreachable:
            // NEITHER non-done answer proves presence: a refusal can
            // be the keychain door failing ("could not tell whose it
            // is — do not claim it is gone", the daemon's own arm) or
            // an unstamped slot that is not ours to touch — and
            // silence can be a landed delete with its reply lost. The
            // ONE read below serves the vault that answers NOW; a
            // dark one earns .unverified without another 17s of
            // patience — the teardown ceiling is sized against
            // exactly these chains.
            switch await vault.read(id: id) {
            case .missing: return .sweptOnReread
            case .unreachable: return .unverified
            default: return .stillPresent
            }
        }
    }

    /// The NE twin of `verifiedDelete`: a removePreferences error on
    /// a cached (or even a fresh) handle cannot tell "refused" from
    /// "already gone" — the removal's reply can be lost, and another
    /// sweeper can land first — so a failure is followed by a FRESH
    /// list re-check, and residue is claimed only when the entry is
    /// actually still there.
    enum EntryRemoval { case removed, alreadyGone, failed, unverified }

    func verifiedEntryRemoval(id: UUID, via provider: TunnelProviding) async -> EntryRemoval {
        if (try? await provider.removePreferences()) != nil { return .removed }
        // One beat before the re-check: an interrupted removal can be
        // mid-commit, and an instant fresh read would report the old
        // state as residue that stops existing a second later.
        try? await Task.sleep(for: .milliseconds(600))
        guard let fresh = try? await systemProviders.loadAllFromPreferences() else {
            return .unverified
        }
        return fresh.contains(where: { $0.tunnelIdentity?.id == id }) ? .failed : .alreadyGone
    }

    /// The last honest question a net can ask once the payload is
    /// gone: did the ENTRY survive? A payload-less entry is filed as
    /// another user's and hidden by the next reload, so the manager's
    /// mirror cannot carry the verdict in either direction — a hidden
    /// survivor reads absent there, and a stale row can outlive an
    /// entry that is already gone (a pruning refresh that lost its
    /// load). Only a FRESH system list answers, and what is acted on
    /// is the MATCHED fresh object itself, never a cached handle —
    /// the house rule `removeEntriesForUninstall` states: no stale
    /// provider object is replayed. An unreadable list is reported as
    /// unverified residue, never clean — the throwaways net's
    /// doctrine, a cleanup that cannot verify is an error.
    func probeHiddenSurvivor(id: UUID) async -> (notes: [String], stuck: Bool) {
        guard let fresh = try? await systemProviders.loadAllFromPreferences() else {
            return (["system list unreadable — entry cleanliness unverified"], true)
        }
        guard let survivor = fresh.first(where: { $0.tunnelIdentity?.id == id }) else {
            // Absent from a fresh system list: provably clean. The
            // mirror may still be showing a stale row for it — align
            // it while there is a deterministic chance.
            if tunnels.tunnels.contains(where: { $0.id == id }) {
                await tunnels.prune()
            }
            return ([], false)
        }
        switch await verifiedEntryRemoval(id: id, via: survivor) {
        case .removed:
            // Deterministic prune, the `cleanupVisibilityBase`
            // precedent: list hygiene must not depend on the
            // debounced refresh.
            await tunnels.prune()
            return (["surviving NE entry removed (a half-completed removal had left it behind)"], false)
        case .alreadyGone:
            await tunnels.prune()
            return (["surviving NE entry already gone by the time it was acted on"], false)
        case .failed:
            return (["surviving NE entry removal failed — check System Settings > VPN"], true)
        case .unverified:
            return (["surviving NE entry removal unverified — system list went unreadable"], true)
        }
    }

    /// Clears a payload whose entry a failed removal already took, and
    /// then LOOKS AGAIN, because the sweep has a racer by construction.
    ///
    /// The removal that produced this residue scheduled a restore on its
    /// way out — that is the whole point of the entry-first order — and
    /// that pass re-proves each candidate by id at the moment it mints.
    /// The fresh list read that sent us here is therefore a round-trip
    /// old before the delete ladder below even starts, and the ladder
    /// can spend seconds against a respawning vault. Mint lands, delete
    /// lands behind it, and what is left is a system entry with no
    /// payload: invisible to the app through the ownership boundary,
    /// undeletable from it, and sitting in the user's System Settings
    /// while this net reports the run clean.
    ///
    /// So the sweep is never the last word. Whatever the delete answers,
    /// the system list is read once more, and an entry that ARRIVED in
    /// the window is taken down through the matched fresh object — the
    /// house rule no stale provider handle is ever replayed. An arm that
    /// only checked before acting would be right most of the time, which
    /// is the worst way for this particular bug to behave.
    ///
    /// Accepted limit, named rather than papered over: this path runs
    /// against the real system, so no harness step can drive it. Its
    /// correctness rests on the second look, not on a witness.
    func sweepOrphanedPayload(id: UUID, error: Error) async -> (notes: [String], stuck: Bool) {
        let verdict = await verifiedDelete(id)
        var notes: [String] = []
        var stuck = false
        switch verdict {
        case .swept, .sweptOnReread:
            notes.append(verdict == .sweptOnReread
                ? "payload swept (an entry-first removal had left it with no entry, verified gone on re-read)"
                : "payload swept (an entry-first removal had left it with no entry)")
        case .stillPresent:
            notes.append("orphan payload still present after a verified sweep — a restore will re-mint it (\(error.localizedDescription))")
            stuck = true
        case .unverified:
            notes.append("orphan payload sweep unverified — vault went dark (\(error.localizedDescription))")
            stuck = true
        }

        // The second look. An entry here was minted by the restore
        // AFTER the read that sent us down this arm, so it is now
        // backed by bytes this sweep has just taken away.
        guard let after = try? await systemProviders.loadAllFromPreferences() else {
            notes.append("entry state after the sweep unverified — system list went unreadable")
            return (notes, true)
        }
        if let arrived = after.first(where: { $0.tunnelIdentity?.id == id }) {
            switch await verifiedEntryRemoval(id: id, via: arrived) {
            case .removed:
                notes.append("a restore had minted an entry into the sweep's window; it was removed")
            case .alreadyGone:
                notes.append("a restore's entry appeared and was gone again by the time it was acted on")
            case .failed:
                notes.append("a restore minted an entry into the sweep's window and it would not come down — check System Settings > VPN")
                stuck = true
            case .unverified:
                notes.append("a restore minted an entry into the sweep's window and its removal is unverified")
                stuck = true
            }
        }
        if tunnels.tunnels.contains(where: { $0.id == id }) {
            await tunnels.prune()
        }
        return (notes, stuck)
    }

    /// The catch arm's resolution, asked rather than inferred. Which
    /// half a throw left behind depends on the order `remove()` chose,
    /// and it chooses per row: a decodable payload is emptied ENTRY
    /// first, so a throw can leave the bytes with no entry; an
    /// undecodable one keeps the old payload-first order, so a throw
    /// there can leave an entry with no bytes. Both pre-deletion exits
    /// leave the pair intact.
    ///
    /// The payload read narrows it but does NOT settle it, and assuming
    /// otherwise is how this arm read the world before the order became
    /// per-row: `.present` is the signature of a pre-deletion exit AND
    /// of an entry-first removal whose payload delete was refused. Only
    /// `.missing` identifies its half on its own; `.present` has to ask
    /// the ENTRY side, which is what separates the two worlds, and then
    /// ask it AGAIN after acting — see `sweepOrphanedPayload` for why
    /// the first answer cannot be the last one.
    func resolveFailedRemove(_ listed: TunnelContainer, id: UUID, error: Error) async -> (notes: [String], stuck: Bool) {
        switch await readPayloadState(id) {
        case .present:
            // Two worlds share this reading and only the ENTRY side
            // separates them: a pre-deletion exit, where the pair is
            // intact and sweeping would hide a listed row, or an
            // entry-first removal whose payload delete was refused,
            // where the bytes are an orphan and keeping them is the
            // wrong answer.
            //
            // The failed removal has just scheduled a restore, and that
            // pass is a live actor for the length of this arm. Waiting
            // the debounce out first is not the guarantee, only the
            // tidy case: it lets the restore either run or prove it is
            // not coming before anything is decided.
            try? await Task.sleep(for: .milliseconds(800))
            guard let fresh = try? await systemProviders.loadAllFromPreferences() else {
                return (["payload present, entry unverifiable — system list went unreadable (\(error.localizedDescription))"], true)
            }
            guard !fresh.contains(where: { $0.tunnelIdentity?.id == id }) else {
                // Visible custody: the entry is really there, so the
                // bytes are reachable and the row renders. Sweeping
                // them would strand what the user can still see.
                return (["entry still listed, payload intact — visible custody kept (\(error.localizedDescription))"], true)
            }
            return await sweepOrphanedPayload(id: id, error: error)
        case .missing:
            // The second half failed: bytes gone, entry listed. Kept,
            // the next reload would file it as another user's and
            // hide it for ever — so it comes down now, while there is
            // still a handle.
            switch await verifiedEntryRemoval(id: id, via: listed.tunnelProvider) {
            case .removed:
                // Deterministic prune: the row is still in the
                // manager's mirror, and nothing else promises a
                // reload (the uninstall latch can silence the
                // debounced one for the process).
                await tunnels.prune()
                return (["remove() half-completed (payload gone) — entry taken down"], false)
            case .alreadyGone:
                await tunnels.prune()
                return (["remove() half-completed (payload gone) — entry already gone"], false)
            case .failed:
                return (["remove() half-completed (payload gone) and the entry refused removal — check System Settings > VPN"], true)
            case .unverified:
                return (["remove() half-completed (payload gone), entry state unverified — system list unreadable"], true)
            }
        case .unreachable:
            return (["remove() failed (\(error.localizedDescription)) and the vault is unreachable — which half survived is unverified, pair left in place"], true)
        }
    }

    /// Sweeps a tunnel a step planted through the FULL path — ground it,
    /// remove it, then ask both stores what is actually left — and
    /// reports the pair in one line.
    ///
    /// Written once because the two nets that needed it were code
    /// identical apart from their label, and both judged cleanliness
    /// from `tunnel(named:)`. The mirror cannot carry that verdict in
    /// either direction: a payload-less entry is filed as another local
    /// user's and drops out of the list while it still sits in the
    /// system store, and an orphan payload was never in the list at all.
    /// "Not listed" is the beginning of the question, not the answer —
    /// which is why this takes the planted `id` and not just the name.
    ///
    /// THE RESPAWN WINDOW is why the removal is tried twice. Grounding
    /// the tunnel takes the tunnel extension down, and that extension
    /// HOSTS the vault listener — so the removal that follows fires
    /// straight into a dark vault, `entryGoesFirst` reads `.unreachable`
    /// and `remove()` refuses outright. That refusal is production
    /// behaving correctly (it will not half-empty a row), so the net
    /// waits for the vault to answer again rather than reading the
    /// refusal as residue. A net that skipped this reported a stuck row
    /// on a machine where nothing was wrong.
    func sweepPlantedTunnel(id: UUID, name: String) async {
        var notes: [String] = []
        var stuck = false

        if let listed = tunnel(named: name) {
            if listed.status != .inactive {
                tunnels.startDeactivation(of: listed)
                guard await awaitStatus(listed, is: .inactive, within: 15) else {
                    // Removing an entry the system is still driving is
                    // the very race this net exists not to widen.
                    log("teardown: \(name) would not ground (status=\(listed.status)) — left in the list on purpose", .error)
                    return
                }
            }
            var removeError: Error?
            do { try await tunnels.remove(tunnel: listed) } catch { removeError = error }
            if case TunnelManagementError.vaultUnavailable? = removeError {
                // The window named above, and the pacing has to come
                // from HERE. `ping()` carries a 5s ceiling but does not
                // spend it when the extension is down: the XPC error
                // handler answers `.unreachable` the moment the
                // connection is invalid, which every run's log shows at
                // boot (`Connection invalidated` followed immediately by
                // `ping error:`). Six un-spaced pings therefore return
                // in milliseconds and the retry fires straight back into
                // the same dark window — the first version of this arm
                // did exactly that while its comment claimed a wait.
                // Bounded by WALL CLOCK, not by an attempt count, and
                // the number is chosen against the teardown ceiling
                // rather than against the respawn alone. This engine
                // gives each net 100s and drops the RESULT past it
                // without stopping the work — a net that overruns never
                // prints its line, which is the one thing the one-line
                // rule forbids. The rest of this member can spend, in
                // the worst all-dark case, ~15s grounding, two removal
                // ladders, a three-attempt read and a delete ladder; an
                // attempt-counted wait stacked on top of that pushed the
                // total past the ceiling. Eight seconds covers the
                // respawn this actually rides out — the suite measures
                // it at ~4s in `Vault Respawn Window Measured` — and
                // leaves the budget for the readings that follow.
                var answered = false
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    if case .ready = await vault.ping() { answered = true; break }
                    try? await Task.sleep(for: .seconds(1))
                }
                if let again = tunnel(named: name) {
                    do { try await tunnels.remove(tunnel: again); removeError = nil } catch { removeError = error }
                } else if answered {
                    // The row left the list while the store was coming
                    // back — the stores below decide whether that was a
                    // removal finishing or a row being hidden.
                    removeError = nil
                }
            }
            if let removeError {
                notes.append("remove refused (\(removeError.localizedDescription))")
                stuck = true
            }
        }

        // Whether the payload is PROVABLY gone, which is the condition
        // the entry probe below is only allowed to run under.
        var payloadGone = false
        switch await readPayloadState(id) {
        case .missing:
            payloadGone = true
        case .present:
            switch await verifiedDelete(id) {
            case .swept, .sweptOnReread:
                notes.append("payload swept")
                payloadGone = true
            case .stillPresent:
                notes.append("payload still in the vault after a verified sweep")
                stuck = true
            case .unverified:
                notes.append("payload sweep unverified — the vault went dark")
                stuck = true
            }
        case .unreachable:
            notes.append("payload state unverified — the vault did not answer")
            stuck = true
        }

        // GATED, and this is the kit's own removal-order doctrine, which
        // the first version of this member broke: `probeHiddenSurvivor`
        // does not merely look — it REMOVES a surviving entry. Run over
        // a payload that is still there, or whose state was never
        // observed, it takes away the only anchor the bytes have and
        // leaves an entry-less payload behind. Its own doc says it is
        // "the last honest question a net can ask ONCE THE PAYLOAD IS
        // GONE"; that condition is this `if`.
        if payloadGone {
            let (entryNotes, entryStuck) = await probeHiddenSurvivor(id: id)
            notes.append(contentsOf: entryNotes)
            stuck = stuck || entryStuck
        } else {
            notes.append("entry left in place — its payload was not observed gone, so it is still the anchor")
        }

        log("teardown: \(name) — \(notes.isEmpty ? "both stores clean" : notes.joined(separator: ", "))",
            stuck ? .error : (notes.isEmpty ? .info : .warn))
    }

}
#endif
