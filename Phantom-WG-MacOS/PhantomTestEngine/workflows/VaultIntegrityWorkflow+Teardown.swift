#if DEBUG
import Foundation

// MARK: - The teardown side of the vault pass: the three-valued reads,
// the re-read-verified deletes and entry removals, the fresh-list probe
// and the net bodies they serve.
//
// Split out of the workflow file when it crossed the length ruler, and
// split HERE because the boundary is real rather than arithmetic: above
// this line the file makes claims about the product, below it the file
// cleans up after having made them. The members are internal rather
// than private for the same reason the sibling step files are — a
// declaration reachable from another file cannot be file-scoped — and
// not because anything outside this engine should call them.
//
// One rule runs through every arm: a cleanup that cannot VERIFY what it
// did reports residue rather than success, and no arm claims a state it
// did not observe.
extension VaultIntegrityWorkflow {
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
        guard let fresh = try? await RealTunnelProviderFactory().loadAllFromPreferences() else {
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
        guard let fresh = try? await RealTunnelProviderFactory().loadAllFromPreferences() else {
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
        guard let after = try? await RealTunnelProviderFactory().loadAllFromPreferences() else {
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
            guard let fresh = try? await RealTunnelProviderFactory().loadAllFromPreferences() else {
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

    /// The corruption base's net body, named the way the visibility
    /// twin names its inline path (`cleanupVisibilityBase`), and
    /// carrying one rule through every arm: the ENTRY never comes down
    /// while bytes it backs might survive — payload first, entry
    /// second.
    ///
    /// The reason is narrower than it used to read here. It is NOT that
    /// a payload without its entry is unreachable in general: for a
    /// DECODABLE payload that is the shape a restore repairs, which is
    /// why `remove()` now empties such a row entry-first on purpose.
    /// It holds for THIS base, whose payload is deliberately corrupt:
    /// `readAll` returns only what decodes, so no restore will ever see
    /// it, and its entry is the only anchor `ingest` can rescue it from.
    /// A payload-less entry is merely hidden by the next reload; an
    /// entry-less undecodable payload is unreachable for ever. Success
    /// is claimed only where it was observed, and an unreachable vault
    /// claims nothing.
    func sweepCorruptionBase(_ base: TunnelContainer, id: UUID, name: String) async {
        var notes: [String] = []
        var stuck = false
        if let listed = tunnel(named: name) {
            do {
                try await tunnels.remove(tunnel: listed)
                notes.append("entry removed")
                // `remove()` deletes the payload itself; with the
                // entry provably gone a surviving leftover gets one
                // more sweep, and no custody decision rides on it.
                switch await readPayloadState(id) {
                case .missing:
                    break // Nothing left.
                case .present:
                    switch await verifiedDelete(id) {
                    case .swept:
                        notes.append("leftover payload swept")
                    case .sweptOnReread:
                        notes.append("leftover payload swept (verified gone on re-read)")
                    case .stillPresent:
                        notes.append("leftover payload still present")
                        stuck = true
                    case .unverified:
                        notes.append("vault unreachable — leftover payload state unverified")
                        stuck = true
                    }
                case .unreachable:
                    notes.append("vault unreachable — leftover payload state unverified")
                    stuck = true
                }
            } catch {
                // `remove()` chooses its order PER ROW, so the throw
                // says even less than it used to about which half
                // survived — which is exactly why the resolver asks the
                // stores instead of inferring from the failure.
                let resolved = await resolveFailedRemove(listed, id: id, error: error)
                notes.append(contentsOf: resolved.notes)
                stuck = stuck || resolved.stuck
            }
        } else {
            switch await readPayloadState(id) {
            case .present:
                // Not listed, but the bytes say the step never swept:
                // the row is hidden rather than gone. Both orders can
                // land here and they leave different things behind, so
                // the arm sweeps the payload FIRST and then asks the
                // system about the entry rather than assuming one.
                // Custody order: a failed payload delete keeps the
                // entry, and with both halves present the next reload
                // reads `.undecodable` and puts the custody row back on
                // the list. Entry-first: the entry is already gone and
                // the payload is an orphan a restore would re-mint. The
                // pair of calls below covers both without having to
                // know which ran.
                let verdict = await verifiedDelete(id)
                switch verdict {
                case .swept, .sweptOnReread:
                    notes.append(verdict == .sweptOnReread
                        ? "payload swept (verified gone on re-read)" : "payload swept")
                    switch await verifiedEntryRemoval(id: id, via: base.tunnelProvider) {
                    case .removed:
                        notes.append("hidden NE entry removed")
                        await tunnels.prune()
                    case .alreadyGone:
                        notes.append("hidden NE entry already gone")
                        await tunnels.prune()
                    case .failed:
                        notes.append("hidden NE entry removal failed — check System Settings > VPN")
                        stuck = true
                    case .unverified:
                        notes.append("hidden NE entry state unverified — system list unreadable")
                        stuck = true
                    }
                case .stillPresent:
                    notes.append("payload still present — hidden NE entry left in place so custody can resurface it")
                    stuck = true
                case .unverified:
                    notes.append("vault unreachable — payload state unverified; hidden NE entry left in place")
                    stuck = true
                }
            case .missing:
                // Neither listed nor backed by bytes — usually clean,
                // unless a removal failed on its second half and a
                // reload has already hidden the survivor. Only the
                // fresh-list probe can answer that.
                let probe = await probeHiddenSurvivor(id: id)
                notes.append(contentsOf: probe.notes)
                stuck = stuck || probe.stuck
            case .unreachable:
                notes.append("vault unreachable — payload state unverified, entry (if any) left in place")
                stuck = true
            }
        }
        log("teardown: corruption base — \(notes.isEmpty ? "already clean" : notes.joined(separator: ", "))",
            stuck ? .error : (notes.isEmpty ? .info : .warn))
    }

    /// The throwaways net's body: payload sweep first (with the
    /// dark and stuck doors), then the bounded entry re-look — the
    /// run's terminal guarantee that no planted id survives in
    /// either store.
    func sweepThrowaways() async {
        let ids = self.tracked.map(\.id) + self.rawIds
        guard !ids.isEmpty else {
            self.log("teardown: nothing was planted")
            return
        }
        // Only what is still there is swept, and only a delete
        // that answered done counts — deleting an id the vault no
        // longer holds also answers done, which is why the read
        // comes first and the count means "was there, now gone".
        // An `.unreachable` read is neither: it proves nothing
        // about that id and it means the next fifteen will each
        // burn their own transport timeout. One is a symptom, a
        // whole run of them is a dark door, so the loop stops and
        // says what it could not check instead of spending
        // minutes discovering the same thing sixteen times.
        var cleared = Set<UUID>()
        var swept = 0
        var stuck = 0
        var unchecked = 0
        var index = 0
        var stuckStreak = 0
        payloadSweep: for id in ids {
            index += 1
            switch await self.vault.read(id: id) {
            case .missing:
                cleared.insert(id)
            case .unreachable:
                unchecked = ids.count - index + 1
                self.log("teardown: vault dark — swept \(swept), still present \(stuck), \(unchecked) of \(ids.count) left unchecked", .error)
                break payloadSweep
            case .config, .undecodable:
                // The dark door's twin for WRITES: one refused
                // delete is a symptom, a streak is a wedged store,
                // and each further retry burns 17s of the ceiling
                // the entry sweep below still needs. Count the
                // rest present without paying for them.
                if stuckStreak >= 2 {
                    stuck += 1
                    continue
                }
                if await self.vault.delete(id: id, attempts: 3) == .done {
                    swept += 1
                    cleared.insert(id)
                    stuckStreak = 0
                } else {
                    stuck += 1
                    stuckStreak += 1
                }
            }
        }
        if unchecked == 0 {
            if swept == 0 && stuck == 0 {
                self.log("teardown: all \(ids.count) planted payload(s) already gone")
            } else {
                self.log("teardown: swept \(swept), still present \(stuck), of \(ids.count) planted", stuck > 0 ? .error : .warn)
            }
        }
        // ENTRY sweep — rides NE, not the vault, so it runs even
        // past a dark door above. A reconcile that ran while
        // planted payloads still had bytes (a dark Delete Proof
        // followed by the corruption step's own reconcile, or the
        // production debounced reload that a net's own entry
        // removal arms) can have MINTED real entries for them;
        // sweeping payloads alone would orphan those entries into
        // exactly the hidden residue this package exists to
        // remove. Payloads went first, so a late reload can no
        // longer re-mint; every entry carrying a planted id comes
        // down off a FRESH list — matched objects only — and the
        // mirror is pruned once. This is the net that runs LAST,
        // so its guarantee is the run's: no planted id survives
        // in either store.
        // Only ids whose payload is CONFIRMED gone: removing an
        // entry while its bytes survive only hands the debounced
        // reload a payload to re-mint from — the pair stays
        // visible instead (the payload summary above already
        // reported it loudly), and every entry removed here has
        // nothing left to resurrect it.
        //
        // BOUNDED RE-LOOK, not one shot: a reconcile already in
        // flight took its readAll snapshot BEFORE the payload
        // sweep, so it can still be holding candidates this net
        // has already deleted. It no longer mints them — the pass
        // re-reads each candidate per id at the moment it mints,
        // and every id swept above answers `.missing` — which
        // leaves one window per CANDIDATE: a probe that answered
        // `.config` in the instant before that id's delete landed,
        // whose entry then arrives a suspension later. The sweep
        // above deletes payloads one at a time, so more than one
        // candidate can be caught that way in the same pass; what
        // shrank is each straggler's odds, not their count. The
        // extra passes below are not sized on any number: they
        // exist because the FIRST clean look is the only thing
        // that can claim clean, and a look taken before a
        // straggler lands is not one.
        var entriesSwept = 0
        var entriesStuck = 0
        var entriesUnverified = 0
        var lookedClean = false
        for pass in 1...3 {
            if pass > 1 {
                // One beat so the in-flight loop's tail and the
                // 400ms debounce it may have armed both land
                // inside it — the re-look then sees their work.
                try? await Task.sleep(for: .milliseconds(800))
            }
            guard let fresh = try? await RealTunnelProviderFactory().loadAllFromPreferences() else {
                self.log("teardown: system list unreadable — minted-entry cleanliness unverified", .error)
                return
            }
            let minted = fresh.filter { provider in
                provider.tunnelIdentity.map { cleared.contains($0.id) } ?? false
            }
            if minted.isEmpty { lookedClean = true; break }
            lookedClean = false
            for provider in minted {
                guard let id = provider.tunnelIdentity?.id else { continue }
                switch await self.verifiedEntryRemoval(id: id, via: provider) {
                case .removed, .alreadyGone: entriesSwept += 1
                case .failed: entriesStuck += 1
                case .unverified: entriesUnverified += 1
                }
            }
            await self.tunnels.prune()
        }
        guard entriesSwept + entriesStuck + entriesUnverified > 0 else { return }
        var parts = ["\(entriesSwept) swept"]
        if entriesStuck > 0 { parts.append("\(entriesStuck) refused removal — check System Settings > VPN") }
        if entriesUnverified > 0 { parts.append("\(entriesUnverified) unverified (system list went unreadable)") }
        if !lookedClean { parts.append("last look still saw a cleared-id entry — a straggler may remain") }
        self.log("teardown: minted entries — \(parts.joined(separator: ", "))",
                 (entriesStuck + entriesUnverified) > 0 || !lookedClean ? .error : .warn)
    }
}
#endif
