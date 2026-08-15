#if DEBUG
import Foundation

/// Stressed data-integrity pass over the vault XPC surface, entirely
/// server-free and deterministic. Uses throwaway configs from
/// `TestConfigFactory`; every payload it stores is deleted before the
/// run ends and `No Materialization` proves the user's tunnel list
/// never noticed. Three failure gates it watches: duplicate entries,
/// stale reads after a rewrite, and read(id) ↔ readAll divergence.
final class VaultIntegrityWorkflow: TestWorkflow {
    override var displayName: String { "Vault Integrity" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Ping Ready", pingReady),
            WorkflowStep("Round-Trip Fidelity", roundTrip),
            WorkflowStep("Rewrite Semantics", rewrite),
            WorkflowStep("Duty Separation (Same Name, Two IDs)", dutySeparation),
            WorkflowStep("Stress Interleave (10 Configs, 3 Rounds)", stressInterleave),
            WorkflowStep("Undecodable Reported Distinctly (read id)", undecodableRead),
            WorkflowStep("Undecodable Not Silently Conflated (read vs readAll)", undecodableAgreement),
            WorkflowStep("Upsert Semantics (Heal + Idempotent Store/Delete)", upsertSemantics),
            WorkflowStep("Delete Proof", deleteProof),
            WorkflowStep("No Materialization", noMaterialization),
            // Custody reads (sibling file). Placed here rather than
            // after the two below so their "run LAST" contract keeps
            // meaning what it says: these drive a fault vault and side
            // managers, touch neither the real vault nor the system's
            // preferences, and plant nothing for a later pass to find.
            WorkflowStep("A Purge Never Touches A Listed Tunnel's Payload", purgeSparesAListedPayload),
            WorkflowStep("Reconcile Proves A Payload Before Minting", reconcileProvesAPayloadBeforeMinting),
            WorkflowStep("Reconcile Marks Its Candidates Before It Probes", reconcileMarksItsCandidateBeforeItAsks),
            WorkflowStep("Reconcile Reads The List Again After Probing", reconcileReadsTheListAgainAfterProbing),
            WorkflowStep("Reconcile Guards The Name It Is About To Write", reconcileGuardsTheNameItIsAboutToWrite),
            WorkflowStep("Reconcile Refuses A Payload It Cannot Trust", reconcileRefusesAPayloadItCannotTrust),
            WorkflowStep("A Dark Vault Stops The Minting Where It Went Dark", reconcileStopsMintingWhenTheVaultGoesDark),
            // Custody writes (sibling file): which store a removal
            // empties first, and what a half-finished removal leaves.
            WorkflowStep("A Removal Takes The Entry First", removalTakesTheEntryFirst),
            WorkflowStep("A Custody Row Keeps Its Entry Until Last", removalKeepsACustodyRowsEntryUntilLast),
            WorkflowStep("A Removal Refuses When The Vault Will Not Answer", removalRefusesWhenTheVaultWillNotAnswer),
            WorkflowStep("Reconcile Does Not Re-Mint An Entry Being Removed", reconcileDoesNotReMintAnEntryBeingRemoved),
            WorkflowStep("A Refused Entry Removal Hands The Row Back", aRefusedEntryRemovalHandsTheRowBack),
            WorkflowStep("A Failed Payload Delete Leaves A Tunnel The Restore Puts Back",
                         aFailedPayloadDeleteLeavesATunnelTheRestorePutsBack),
            WorkflowStep("A Teardown That Took The Store Stops The Restore",
                         aTeardownThatTookTheStoreStopsTheRestore),
            WorkflowStep("Realign Stands Down When A Teardown Takes The Store",
                         realignStandsDownWhenATeardownTakesTheStore),
            WorkflowStep("The Uninstall Sweep Does Not Write To A Row Being Removed",
                         theUninstallSweepDoesNotWriteToARowBeingRemoved),
            // These two run LAST, on a vault holding only the door
            // configs: they are the only steps whose reconcile reads
            // the REAL vault (via add) — and the visibility gate drives
            // a full reload besides. Keeping them after Delete Proof
            // stops those passes from materialising the bulk throwaways
            // this run had stored. The custody-read steps above
            // reconcile too, but every one of them over a fabricated
            // vault, so no throwaway of this run is ever a candidate
            // for them.
            WorkflowStep("Entry Survives Corruption (Reconcile)", corruptionSurvival),
            WorkflowStep("Undecodable Payload Stays Listed (Reload)", custodyVisibility),
        ]
    }

    /// Everything this run ever stored — Delete Proof sweeps it all,
    /// even when an earlier step failed halfway.
    ///
    /// Readable from the teardown file and writable only here, which is
    /// the shape the ledger actually has: the steps are the only things
    /// that may add to it, and the net is the only thing that reads it.
    /// This is also the coupling that keeps the sweep kit tied to THIS
    /// workflow rather than shared — promoting it means parameterising
    /// these two out first.
    private(set) var tracked: [TunnelConfig] = []
    /// Ids written as RAW (undecodable) bytes via the injection client;
    /// swept alongside `tracked` so no corrupt payload is left behind.
    private(set) var rawIds: [UUID] = []
    // Reachable from the sibling file that carries the custody-read
    // steps.
    let runTag = String(UUID().uuidString.prefix(8))

    // MARK: - Steps

    private func pingReady() async {
        // Registered from the first step, before anything is planted:
        // the stashes are read when the net RUNS, so it sweeps
        // whatever the run got as far as storing. Delete Proof stays
        // the owner and keeps earning its absence proof on the normal
        // path — by the time this runs there, both stashes read
        // `.missing` already and it reports a clean zero.
        onTeardown("vault throwaways") { [weak self] in
            await self?.sweepThrowaways()
        }
        switch await vault.ping() {
        case .ready(let payloads, let identity):
            log("vault ready — identity=\(identity) payloads=\(payloads)", .ok)
        case .doorFailed(let identity):
            fail("extension answered but the keychain door failed — identity=\(identity)")
        case .unreachable:
            // The suite-wide doctrine, one sentence: a claim that
            // depends on the vault SKIPs when the vault does not
            // answer (silence proves nothing about the claim), while a
            // CLEANUP that cannot reach the vault reports an error
            // (residue is real whatever the reason).
            skip("environment: vault unreachable")
        }
    }

    private func roundTrip() async {
        guard let standalone = TestConfigFactory.throwaway(name: "TE-RT-\(runTag)"),
              let ghost = TestConfigFactory.throwaway(name: "TE-RT-Ghost-\(runTag)", ghost: true) else {
            fail("factory produced no config")
            return
        }
        for cfg in [standalone, ghost] {
            tracked.append(cfg)
            let stored = await vault.store(cfg)
            guard stored == .done else {
                fail("store \(stored.label): \(cfg.name)")
                continue
            }
            switch await vault.read(id: cfg.id) {
            case .config(let back):
                check(back == cfg, "\(cfg.name): read back equal to what was stored (ghost=\(cfg.isGhostMode))")
            case .missing:
                fail("\(cfg.name): stored but read .missing")
            case .undecodable:
                fail("\(cfg.name): stored a valid config but read .undecodable")
            case .unreachable:
                skip("environment: vault unreachable after store — \(cfg.name) round-trip unproven")
            }
        }
    }

    private func rewrite() async {
        guard let original = tracked.first else {
            skip("no base config from Round-Trip")
            return
        }
        var v2 = original
        v2.name = original.name + "-v2"
        let storedV2 = await vault.store(v2)
        guard storedV2 == .done else {
            fail("rewrite store \(storedV2.label)")
            return
        }
        tracked[0] = v2
        switch await vault.read(id: original.id) {
        case .config(let back):
            check(back == v2 && back.name != original.name,
                  "same id reads back the rewritten payload (name=\(back.name)) — no stale read")
        case .missing:
            fail("payload vanished on rewrite")
        case .undecodable:
            fail("rewrote a valid config but read .undecodable")
        case .unreachable:
            skip("environment: vault unreachable after rewrite — claim unproven")
        }
    }

    private func dutySeparation() async {
        guard let base = tracked.first else {
            skip("no base config from Round-Trip")
            return
        }
        guard let twin = TestConfigFactory.throwaway(name: base.name) else {
            fail("factory produced no twin")
            return
        }
        tracked.append(twin)
        let storedTwin = await vault.store(twin)
        guard storedTwin == .done else {
            fail("twin store \(storedTwin.label)")
            return
        }
        // Payload identity, not mere decodability: each id must hand
        // back ITS OWN payload — a name-keyed vault could serve one
        // payload from both ids and still pass a decodability check.
        guard case .config(let backBase) = await vault.read(id: base.id) else {
            fail("base did not read back .config")
            return
        }
        guard case .config(let backTwin) = await vault.read(id: twin.id) else {
            fail("twin did not read back .config")
            return
        }
        check(backBase == base && backTwin == twin && base.id != twin.id,
              "two payloads share name \"\(base.name)\" under distinct ids — the vault keys on id, name uniqueness stays TunnelsManager's duty")
    }

    private func stressInterleave() async {
        guard case .configs(let baseline) = await vault.readAll() else {
            skip("environment: readAll unreachable at baseline")
            return
        }
        var expected = Set(baseline.map(\.id))
        log("baseline: \(expected.count) payloads")

        var pool: [TunnelConfig] = []
        for index in 0..<10 {
            guard let cfg = TestConfigFactory.throwaway(name: "TE-Stress-\(index)-\(runTag)") else {
                fail("factory failed at #\(index)")
                return
            }
            pool.append(cfg)
        }
        tracked.append(contentsOf: pool)

        for cfg in pool {
            if case let outcome = await vault.store(cfg), outcome != .done { fail("store \(outcome.label): \(cfg.name)") }
            expected.insert(cfg.id)
        }
        await verifyExactSet(expected, "after storing 10")

        for (index, cfg) in pool.enumerated() where index % 2 == 0 {
            if case let outcome = await vault.delete(id: cfg.id), outcome != .done { fail("delete \(outcome.label): \(cfg.name)") }
            expected.remove(cfg.id)
        }
        await verifyExactSet(expected, "after deleting 5")

        for (index, cfg) in pool.enumerated() where index % 2 == 0 {
            if case let outcome = await vault.store(cfg), outcome != .done { fail("re-store \(outcome.label): \(cfg.name)") }
            expected.insert(cfg.id)
        }
        await verifyExactSet(expected, "after re-storing 5")
    }

    /// A payload present in the vault but not decodable must not read
    /// the same as one that is truly absent — otherwise the ingest
    /// ownership probe, which trusts "missing" as "not this user's",
    /// would take our own broken payload for a stranger's entry and
    /// hide the row that is its only surface. read(id) reports a
    /// decode failure as `.undecodable`, distinct from `.missing`; this
    /// guards that distinction.
    private func undecodableRead() async {
        let corruptId = UUID()
        let absentId = UUID() // never written — the honest "absent" baseline
        guard await vaultRaw.storeRaw(Data("not-a-tunnelconfig".utf8), id: corruptId) else {
            fail("raw store refused — vault unreachable")
            return
        }
        rawIds.append(corruptId)
        let corrupt = await vault.read(id: corruptId)
        if case .unreachable = corrupt {
            skip("environment: vault unreachable — distinctness unproven")
            return
        }
        let absent = await vault.read(id: absentId)
        // Exact pair, not mere inequality: a regression mapping
        // undecodable to .missing would still differ from a transient
        // .unreachable on the absent read — an inequality check would
        // pass with the guarded regression live.
        guard case .undecodable = corrupt else {
            fail("planted payload did not read back .undecodable — got \(label(corrupt))")
            return
        }
        guard case .missing = absent else {
            fail("absent baseline did not answer .missing — got \(label(absent))")
            return
        }
        check(true, "undecodable distinct from absent — corrupt=\(label(corrupt)) absent=\(label(absent))")
    }

    /// An undecodable payload must not be silently conflated with an
    /// absent one across the read surfaces. read(id) is the surface
    /// the ingest ownership probe (and the slot classifier) trusts
    /// for its foreign-or-custody verdict, so it must surface the
    /// payload as `.undecodable`; readAll legitimately excludes it
    /// from its decoded answer (the per-id probe exists because it
    /// does), so the invariant is "read(id) surfaces it", not "both
    /// list it".
    private func undecodableAgreement() async {
        guard let id = rawIds.last else {
            skip("no corrupt payload planted")
            return
        }
        let byId = await vault.read(id: id)
        guard case .configs(let all) = await vault.readAll() else {
            skip("environment: readAll unreachable — agreement unproven")
            return
        }
        let inReadAll = all.contains { $0.id == id }
        // Positive claim, not a negated conjunction: the per-id
        // surface must answer .undecodable itself — the old shape
        // (only forbidding missing-AND-excluded) let a transient
        // .unreachable read pass as agreement.
        guard case .undecodable = byId else {
            fail("read(id) did not surface the planted payload as .undecodable — got \(label(byId))")
            return
        }
        check(!inReadAll, "read(id) surfaces undecodable, not conflated with absent — read(id)=\(label(byId)), readAll's decoded answer excludes it (inReadAll=\(inReadAll))")
    }

    /// Corrupt a real tunnel's payload in place, then reconcile. The
    /// entry — and the secret bytes — must survive: a broken payload is
    /// a custody problem to surface, not a licence to delete the entry.
    /// reconcile is purely additive — no path in it removes an entry —
    /// and this step pins that shape from the outside; it guards
    /// against a removal path growing back and orphaning the secret.
    private func corruptionSurvival() async {
        let name = "TE-Corrupt-\(runTag)"
        guard let cfg = TestConfigFactory.throwaway(name: name) else {
            fail("factory produced no config")
            return
        }
        // The container is kept for the net below, not for the step:
        // once the payload is corrupt the ownership filter can drop
        // this row out of the list, and then this reference is the
        // only handle left on the system entry.
        guard let base = try? await tunnels.add(config: cfg) else {
            fail("add failed for the corruption base")
            return
        }
        // The heaviest residue in this workflow, and the one Delete
        // Proof cannot reach: a REAL system entry whose payload is
        // about to be corrupted. The loud inline cleanup below owns
        // the normal path; under a Stop it cannot run at all, and what
        // survives is exactly the custody-visibility shape — an entry
        // the list keeps rendering with bytes nothing can decode.
        onTeardown("corruption base") { [weak self] in
            await self?.sweepCorruptionBase(base, id: cfg.id, name: name)
        }
        guard await vaultRaw.storeRaw(Data("corrupt".utf8), id: cfg.id) else {
            fail("raw corrupt store refused")
            return
        }
        _ = await tunnels.reconcileFromVault()
        let survived = tunnel(named: name) != nil
        check(survived, survived
            ? "entry survived a corrupted payload through reconcile"
            : "entry DROPPED after payload corruption — secret orphaned (a removal path has grown back into reconcile)")
        // The doc's claim is two survivals, and until now only one was
        // measured: the ROW. The BYTES are the other half — reconcile
        // must not have deleted or replaced the corrupt payload, and
        // `.undecodable` is the only answer that proves it is still
        // there as written (`.missing` would mean the secret was
        // dropped, `.config` that something rewrote it).
        switch await vault.read(id: cfg.id) {
        case .undecodable:
            check(true, "the corrupt bytes themselves survived reconcile (.undecodable)")
        case .missing:
            fail("the corrupt payload was DELETED during reconcile — the secret did not survive")
        case .config:
            fail("the corrupt payload was REWRITTEN during reconcile — not the bytes that were stored")
        case .unreachable:
            skip("environment: vault unreachable — byte-survival unproven")
        }
        // Loud cleanup, mirroring the visibility twin: this id is
        // never tracked, so Delete Proof cannot see its leftovers —
        // a failed sweep must say so instead of leaving a corrupt
        // payload or a TE-Corrupt entry behind in silence.
        if let t = tunnel(named: name) {
            do { try await tunnels.remove(tunnel: t) } catch {
                log("cleanup: entry remove failed — \(name) lingers in the list (\(error.localizedDescription))", .warn)
            }
        }
        if await vault.delete(id: cfg.id, attempts: 3) != .done {
            log("cleanup: corrupt payload delete failed — \(name) lingers in the vault", .warn)
        }
    }

    /// The visibility half of the custody contract. Corrupt a real
    /// tunnel's payload, then run the user's reload path: the tunnel
    /// must STAY in the list. readAll legitimately excludes an
    /// undecodable payload from its decodable-config answer, so the
    /// ingest ownership boundary — which scopes the list by that
    /// answer — would, unaided, mistake our own broken payload for
    /// another local user's entry and hide it. Hidden is broken
    /// custody: the detail screen's "config unavailable" surface is
    /// reachable only through the list row, so a vanished row strands
    /// the secret with no path to see, delete, or re-import it.
    private func custodyVisibility() async {
        let name = "TE-Visible-\(runTag)"
        guard let cfg = TestConfigFactory.throwaway(name: name) else {
            fail("factory produced no config")
            return
        }
        guard let container = try? await tunnels.add(config: cfg) else {
            fail("add failed for the visibility base")
            return
        }
        // Same class as the corruption base, with one twist: this row
        // may be HIDDEN from the list when the gate is red, so the net
        // holds the container rather than looking the name up — the
        // entry has to come down even when the list will not show it.
        onTeardown("visibility base") { [weak self] in
            guard let self else { return }
            var notes: [String] = []
            var stuck = false
            // The payload is the pivot, read three-valued and
            // retried: present means the step's own cleanup never
            // completed and the entry must still be there; missing
            // hands the verdict to the fresh-list probe; unreachable
            // verifies nothing and so claims nothing — as residue,
            // loudly. The manager's list alone cannot carry any of
            // it: this row can be HIDDEN when the gate is red, and a
            // stale mirror can outlive an entry that is already gone
            // — which is why the net holds the container for the
            // present arm and asks the fresh system list for the
            // missing one.
            switch await self.readPayloadState(cfg.id) {
            case .present:
                // Payload first, and a failed delete KEEPS the entry —
                // the same order and the same rule
                // `cleanupVisibilityBase` spells out. Removing the
                // entry over a surviving payload would strand the
                // bytes with no list row, no detail surface and no
                // path ever to see or clear them: the exact
                // broken-custody state this gate exists to prevent.
                let verdict = await self.verifiedDelete(cfg.id)
                switch verdict {
                case .swept, .sweptOnReread:
                    notes.append(verdict == .sweptOnReread
                        ? "payload swept (verified gone on re-read)" : "payload swept")
                    switch await self.verifiedEntryRemoval(id: cfg.id, via: container.tunnelProvider) {
                    case .removed:
                        notes.append("NE entry removed")
                        await self.tunnels.prune()
                    case .alreadyGone:
                        notes.append("NE entry already gone")
                        await self.tunnels.prune()
                    case .failed:
                        notes.append("NE entry removal failed — check System Settings > VPN")
                        stuck = true
                    case .unverified:
                        notes.append("NE entry state unverified — system list unreadable")
                        stuck = true
                    }
                case .stillPresent:
                    notes.append("payload still present — NE entry left in place so the custody row stays reachable")
                    stuck = true
                case .unverified:
                    notes.append("vault unreachable — payload state unverified; NE entry left in place")
                    stuck = true
                }
            case .missing:
                // Payload gone — whether the row still shows or a
                // reload has already hidden it, the mirror cannot
                // carry the verdict (stale in both directions, and a
                // bare removePreferences on an entry that is already
                // gone would invent residue). The fresh-list probe
                // answers both shapes, prunes a stale row, and earns
                // "already clean" instead of assuming it.
                let probe = await self.probeHiddenSurvivor(id: cfg.id)
                notes.append(contentsOf: probe.notes)
                stuck = stuck || probe.stuck
            case .unreachable:
                notes.append("vault unreachable — payload state unverified, entry (if any) left in place")
                stuck = true
            }
            self.log("teardown: visibility base — \(notes.isEmpty ? "already clean" : notes.joined(separator: ", "))",
                     stuck ? .error : (notes.isEmpty ? .info : .warn))
        }
        guard await vaultRaw.storeRaw(Data("corrupt".utf8), id: cfg.id) else {
            fail("raw corrupt store refused")
            await cleanupVisibilityBase(container, cfg.id)
            return
        }
        // Precondition, proven not assumed: the payload now reads
        // .undecodable — present but unreadable, distinct from absent.
        guard case .undecodable = await vault.read(id: cfg.id) else {
            fail("precondition broke — read(id) did not answer .undecodable after the corrupt write")
            await cleanupVisibilityBase(container, cfg.id)
            return
        }
        await tunnels.refresh()
        let visible = tunnels.tunnels.contains { $0.id == cfg.id }
        check(visible, visible
            ? "tunnel stayed listed through a reload with an undecodable payload — custody remains visible"
            : "tunnel VANISHED from the list after a reload — the ownership filter"
                + " took an undecodable own payload for another user's entry")
        await cleanupVisibilityBase(container, cfg.id)
    }

    /// Tears down the visibility base: payload first, entry second —
    /// and only in that order, loudly. If the payload delete fails the
    /// NE entry stays put on purpose: the row keeps rendering (custody),
    /// so whatever stranded is still visible and clearable by hand. The
    /// container ref survives ingest, so the entry comes down even
    /// while the list hides the tunnel (this gate's RED state).
    private func cleanupVisibilityBase(_ container: TunnelContainer, _ id: UUID) async {
        guard await vault.delete(id: id, attempts: 3) == .done else {
            log("cleanup: vault delete failed — NE entry left in place so the custody row stays reachable", .warn)
            return
        }
        if (try? await container.tunnelProvider.removePreferences()) == nil {
            log("cleanup: NE entry removal failed — an unbacked entry may linger in System Settings > VPN", .warn)
        } else {
            // Prune the hidden container deterministically: list
            // hygiene must not depend on the debounced refresh being
            // alive (an uninstall latch silences it for the process).
            // Prune, not refresh: a full reload's reconcile could
            // mint entries for plants a later net still has to sweep.
            await tunnels.prune()
        }
    }

    /// The upsert's contract, pinned from the caller's side. Three
    /// claims, each load-bearing: a valid store over an id holding
    /// corrupt bytes heals the slot in place (the user's re-import
    /// recovery — the one cell of the corrupt/valid matrix no other
    /// step reaches); storing the same payload twice changes nothing
    /// (the client's retry ladder re-stores after a timeout that hid a
    /// landed write); and deleting an absent or already-deleted id
    /// answers done (remove()'s retry path wedges the tunnel as
    /// unremovable if this ever regresses).
    private func upsertSemantics() async {
        guard let cfg = TestConfigFactory.throwaway(name: "TE-Heal-\(runTag)") else {
            fail("factory produced no config")
            return
        }
        tracked.append(cfg)
        guard await vaultRaw.storeRaw(Data("corrupt".utf8), id: cfg.id) else {
            fail("raw corrupt store refused")
            return
        }
        guard case .undecodable = await vault.read(id: cfg.id) else {
            fail("precondition broke — corrupt write did not read .undecodable")
            return
        }
        let healed = await vault.store(cfg)
        guard healed == .done else {
            fail("valid store over a corrupt slot \(healed.label) — heal-in-place unproven")
            return
        }
        if case .config(let healed) = await vault.read(id: cfg.id) {
            check(healed == cfg, "valid store over corrupt bytes healed the slot in place")
        } else {
            fail("healed slot did not read back as a config")
        }

        let restored = await vault.store(cfg)
        guard restored == .done else {
            fail("second identical store \(restored.label) — a retry after a timed-out-but-landed write would not be harmless")
            return
        }
        if case .config(let again) = await vault.read(id: cfg.id) {
            check(again == cfg, "storing the same payload twice reads back unchanged")
        } else {
            fail("double-stored slot did not read back as a config")
        }

        check(await vault.delete(id: UUID()) == .done, "deleting a never-stored id answers done")
        guard let twice = TestConfigFactory.throwaway(name: "TE-DelTwice-\(runTag)") else {
            fail("factory produced no config")
            return
        }
        tracked.append(twice)
        let storedTwice = await vault.store(twice)
        guard storedTwice == .done else {
            fail("store \(storedTwice.label): \(twice.name)")
            return
        }
        check(await vault.delete(id: twice.id) == .done, "first delete answers done")
        check(await vault.delete(id: twice.id) == .done, "second delete of the same id answers done")
        if case .missing = await vault.read(id: twice.id) {
            log("deleted id reads back .missing", .ok)
        } else {
            fail("deleted id did not read back .missing")
        }
    }

    private func deleteProof() async {
        // The skip guard covers BOTH stashes and sits before any
        // delete: a run whose factory failed but whose injection
        // steps planted raw bytes must still prove those bytes gone,
        // not sweep them unverified behind a "nothing was stored".
        guard !tracked.isEmpty || !rawIds.isEmpty else {
            skip("nothing was stored")
            return
        }
        // Same patience for both stashes: a vault respawn window does
        // not care which client wrote the payload, and the impatient
        // single shot the tracked configs used to get was the one that
        // left them behind when the door was mid-restart.
        for id in rawIds {
            await vault.delete(id: id, attempts: 3)
        }
        for cfg in tracked {
            await vault.delete(id: cfg.id, attempts: 3)
        }
        var gone = 0
        for cfg in tracked {
            if case .missing = await vault.read(id: cfg.id) { gone += 1 }
        }
        // The raw plants get the same absence proof as the tracked
        // configs — a corrupt item surviving its delete must fail this
        // step, not slip through as a quiet leftover.
        var rawGone = 0
        for id in rawIds {
            if case .missing = await vault.read(id: id) { rawGone += 1 }
        }
        check(gone == tracked.count && rawGone == rawIds.count,
              "all \(tracked.count) throwaways and \(rawIds.count) raw plants read back .missing (\(gone)+\(rawGone) confirmed)")
    }

    private func noMaterialization() async {
        // The in-memory list is the sample, deliberately unforced.
        // Two separate facts make it the right one: a reload now could
        // not mint anything (the payloads are already deleted), and it
        // WOULD hide a row minted earlier — ingest files a payload-less
        // row under another user. The unreloaded list is therefore the
        // only surface that can still show the damage. The suite's own
        // steps do not reshape it (they touch only the vault, which
        // posts no configuration-change notification), but one outside
        // reshaper exists: a foreground return mid-run schedules a
        // reload, and a row minted before it would be hidden by it.
        // Accepted as a limit — a check that can miss under an
        // app-switch is still worth more than one blinded by its own
        // sampling.
        let ids = Set(tracked.map(\.id))
        let materialized = tunnels.tunnels.filter { ids.contains($0.id) }
        check(materialized.isEmpty,
              "no throwaway materialized into the tunnel list (\(materialized.count) found)")
        // "Intact" must mean the PAYLOAD answers, not just the row:
        // custody-visibility keeps a row listed even when its payload
        // is broken, so presence-by-name alone cannot detect the
        // exact damage this step rules out.
        var doorsIntact = true
        for name in [TestContext.ghostName, TestContext.wireGuardName] {
            guard let door = tunnel(named: name),
                  case .config = await vault.read(id: door.id) else {
                doorsIntact = false
                continue
            }
        }
        check(doorsIntact, "door configs intact — rows listed and payloads decode")
    }

    // MARK: - Shared

    private func label(_ read: TunnelVaultClient.Read) -> String {
        switch read {
        case .config:      return "config"
        case .missing:     return "missing"
        case .undecodable: return "undecodable"
        case .unreachable: return "unreachable"
        }
    }

    /// The read(id) ↔ readAll divergence gate: the enumeration must be
    /// EXACTLY the expected id set — nothing missing, nothing extra,
    /// and no id listed twice.
    private func verifyExactSet(_ expected: Set<UUID>, _ label: String) async {
        guard case .configs(let all) = await vault.readAll() else {
            skip("environment: readAll unreachable \(label) — set equality unproven")
            return
        }
        let actual = all.map(\.id)
        let actualSet = Set(actual)
        let missing = expected.subtracting(actualSet)
        let extra = actualSet.subtracting(expected)
        let duplicates = actual.count - actualSet.count
        check(missing.isEmpty && extra.isEmpty && duplicates == 0,
              "\(label): \(actual.count) payloads — missing=\(missing.count) extra=\(extra.count) duplicates=\(duplicates)")
    }
}
#endif
