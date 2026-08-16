#if DEBUG
import Foundation

// MARK: - The two teardown arms that belong to THIS pass and could not
// be shared: the throwaway sweep and the corruption base.
//
// The rest of what used to live here — the three-valued read, the
// re-read-verified delete and entry removal, the fresh-list probe and
// the two repair arms — moved to `TestWorkflow+VerifiedSweep.swift`,
// because every workflow that plants something owes the same honesty.
// These two stayed for reasons that are about the arms, not about
// tidiness:
//
// `sweepThrowaways` reads this workflow's own planted ledgers
// (`tracked`, `rawIds`), so it has no meaning on a workflow that
// planted something else.
//
// `sweepCorruptionBase` carries a doctrine that holds for exactly one
// base. Its payload is deliberately corrupt, `readAll` never returns
// it, and therefore no restore can ever repair it — which is what makes
// taking the entry LAST correct here and wrong for a decodable row.
// Promoted, it would hand other workflows a reasoning that does not
// apply to them, and its own net label with it.
//
// Both still run on the promoted kit, and the rule the kit carries
// governs them: a cleanup that cannot VERIFY what it did reports
// residue rather than success, and no arm claims a state it did not
// observe.
extension VaultIntegrityWorkflow {
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
        // Payloads whose delete neither confirmed nor refused: the
        // store went dark on the re-read, so the bytes may be gone or
        // may not. Counted apart from `stuck` because the two ask for
        // different things — one says come back and delete, the other
        // says come back and LOOK.
        var unverified = 0
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
                // Through the kit — and it was the kit's OWN member
                // that still read a delete as a Bool here. (Not the
                // last one in the engine: the corrupt-plant STEP in
                // IsolationWorkflow still reads three of them that way,
                // and those are step assertions rather than cleanup
                // verdicts, which is a different question.) The
                // distinction is load-bearing twice over: a silence
                // that turns out to be a landed delete counted as
                // "still present" before, and `cleared` decides which
                // ENTRIES the sweep below may remove, so an id whose
                // payload was never observed gone must not enter it.
                switch await self.verifiedDelete(id) {
                case .swept, .sweptOnReread:
                    swept += 1
                    cleared.insert(id)
                    stuckStreak = 0
                case .stillPresent:
                    stuck += 1
                    stuckStreak += 1
                case .unverified:
                    unverified += 1
                    stuckStreak += 1
                }
            }
        }
        if unchecked == 0 {
            if swept == 0 && stuck == 0 && unverified == 0 {
                self.log("teardown: all \(ids.count) planted payload(s) already gone")
            } else {
                let unverifiedNote = unverified > 0 ? ", \(unverified) unverified (the store went dark on the re-read)" : ""
                self.log("teardown: swept \(swept), still present \(stuck)\(unverifiedNote), of \(ids.count) planted",
                         stuck > 0 || unverified > 0 ? .error : .warn)
            }
        }
        await self.sweepMintedEntries(cleared: cleared)
    }

    /// The ENTRY half of the throwaway sweep, split out when the
    /// payload half's move onto the kit pushed the whole net past
    /// the length ruler. The boundary is the one the net already
    /// drew in prose: above it the vault is swept, here the system
    /// store is.

    /// ENTRY sweep — rides NE, not the vault, so it runs even
    /// past a dark door above. A reconcile that ran while
    /// planted payloads still had bytes (a dark Delete Proof
    /// followed by the corruption step's own reconcile, or the
    /// production debounced reload that a net's own entry
    /// removal arms) can have MINTED real entries for them;
    /// sweeping payloads alone would orphan those entries into
    /// exactly the hidden residue this package exists to
    /// remove. Payloads went first, so a late reload can no
    /// longer re-mint; every entry carrying a planted id comes
    /// down off a FRESH list — matched objects only — and the
    /// mirror is pruned once. This is the net that runs LAST,
    /// so its guarantee is the run's: no planted id survives
    /// in either store.
    /// Only ids whose payload is CONFIRMED gone: removing an
    /// entry while its bytes survive only hands the debounced
    /// reload a payload to re-mint from — the pair stays
    /// visible instead (the payload summary above already
    /// reported it loudly), and every entry removed here has
    /// nothing left to resurrect it.
    ///
    /// BOUNDED RE-LOOK, not one shot: a reconcile already in
    /// flight took its readAll snapshot BEFORE the payload
    /// sweep, so it can still be holding candidates this net
    /// has already deleted. It no longer mints them — the pass
    /// re-reads each candidate per id at the moment it mints,
    /// and every id swept above answers `.missing` — which
    /// leaves one window per CANDIDATE: a probe that answered
    /// `.config` in the instant before that id's delete landed,
    /// whose entry then arrives a suspension later. The sweep
    /// above deletes payloads one at a time, so more than one
    /// candidate can be caught that way in the same pass; what
    /// shrank is each straggler's odds, not their count.
    ///
    /// And that sweep is NOT the only delete this net stands
    /// behind — usually it is not even the one that pays. Every
    /// earlier delete in this workflow opens the same window,
    /// `Delete Proof`'s pass above all: it removes materialized
    /// rows through `remove()` and then deletes their payloads,
    /// and the removals themselves wake the reload whose probe
    /// straddles those deletes. On a run where that pass swept
    /// everything, the sweep above finds nothing to delete and
    /// its own window never opens — while a straggler can still
    /// be standing here. Read one clean look as the claim, not
    /// the delete count of any single pass.
    ///
    /// The extra passes below are not sized on any number: they
    /// exist because the FIRST clean look is the only thing
    /// that can claim clean, and a look taken before a
    /// straggler lands is not one.
    private func sweepMintedEntries(cleared: Set<UUID>) async {
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
                guard let fresh = try? await systemProviders.loadAllFromPreferences() else {
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
