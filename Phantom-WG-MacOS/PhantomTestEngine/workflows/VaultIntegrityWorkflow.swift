#if DEBUG
import Foundation

/// Stressed data-integrity pass over the vault XPC surface, entirely
/// server-free and deterministic. Uses throwaway configs from
/// `TestConfigFactory`; every payload it stores is deleted before the
/// run ends.
///
/// The user's tunnel list may legitimately NOTICE, and that is not a
/// defect on either side: these payloads live in the real vault, so a
/// reconcile pass firing mid-run restores them exactly as it would any
/// payload the system had lost. What the suite owes is the order —
/// `Delete Proof` removes such a row through `remove()` before any
/// payload is deleted, so no entry is ever left without its secret —
/// and `No Materialization` proves the list is clean when the pass is
/// over. Three failure gates it watches: duplicate entries, stale reads
/// after a rewrite, and read(id) ↔ readAll divergence.
final class VaultIntegrityWorkflow: TestWorkflow {
    override var displayName: String { "Vault Integrity" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Ping Ready", pingReady),
            WorkflowStep("Round-Trip Fidelity", roundTrip),
            WorkflowStep("A Retry Does Not Answer From A Proven Silence",
                         retryDoesNotAnswerFromAProvenSilence),
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
            WorkflowStep("A Restore Puts The Tunnel Back As An Entry", aRestorePutsTheTunnelBackAsAnEntry),
            // Custody writes (sibling file): which store a removal
            // empties first, and what a half-finished removal leaves.
            WorkflowStep("A Refused Vault Write Reads Differently From A Silent One",
                         aRefusedVaultWriteReadsDifferentlyFromASilentOne),
            WorkflowStep("A Creation Yields To A Row The List Already Took",
                         createEntryYieldsToARowTheListAlreadyTook),
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
            WorkflowStep("The Uninstall Removal Takes Only The Classified Entries",
                         theUninstallRemovalTakesOnlyTheClassifiedEntries),
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

    /// Everything this run stored through the THROWAWAY path — Delete
    /// Proof sweeps that, even when an earlier step failed halfway. The
    /// corruption and visibility bases sit outside it on purpose and
    /// carry their own nets; the line where the first of them is planted
    /// says so.
    ///
    /// Readable from the teardown file and writable only here, which is
    /// the shape the ledger actually has: the steps are the only things
    /// that may add to it, and the net is the only thing that reads it.
    /// This is the coupling that keeps `sweepThrowaways` tied to THIS
    /// workflow. The kit it runs on is shared — it lives on the base as
    /// `TestWorkflow+VerifiedSweep.swift` — but a net that reads these
    /// two ledgers has no meaning on a workflow that planted something
    /// else, so this arm stayed behind when the rest moved.
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

    /// A retry does not answer itself from a silence that was already
    /// proven — it asks again, which is the only thing a retry is for.
    ///
    /// The dark window spares independent callers the cost of a silence
    /// someone else has just paid for. A ladder is not one of those: it
    /// sleeps precisely so it can ask a second time, and what it needs
    /// to learn is whether the extension has come back. The three
    /// ladders sleep 600ms then 1200ms, against a 2s window, so while
    /// the retries read the window every attempt fell inside the first
    /// one's verdict and the extension was never asked at all.
    ///
    /// The claim is carried by the OUTCOME. A ladder that honours the
    /// window on its retries answers `.unreachable` over a vault that is
    /// right there; one that discards the proven silence answers
    /// `.done`.
    ///
    /// The arrangement is proven by the client's own SPARED COUNT rather
    /// than by wall clock, and on a client this step OWNS rather than
    /// the app's. Both halves of that were learned from red runs:
    ///
    /// A duration read against the 0.6s backoff left a couple of hundred
    /// milliseconds between "the window was in the way" and "the window
    /// had lapsed and the first attempt simply answered" — a step whose
    /// whole job is to notice a reverted fix must not be one scheduling
    /// slip from a false green. One spared call says the discard ran;
    /// MORE than one says the ladder answered itself from the window.
    ///
    /// That reading rests on one relation, named so it can be rechecked
    /// rather than trusted: the ladder's backoffs before its last
    /// attempt must total less than `darkWindow`. Today that is
    /// 600ms + 1200ms against 2s. Widen the window or lengthen the
    /// backoffs and a reverted discard starts spending its third attempt
    /// outside the window, which lowers the spared count and softens
    /// this step's red — so those two numbers are this assertion's
    /// premise, not incidental.
    ///
    /// And the count has to come off a PRIVATE client. Measured on the
    /// app's shared one it read 0 on two runs and 2 on a third, for two
    /// different reasons: the log's own counter is zeroed by any real
    /// answer, and a monotonic one is inflated by whatever else the main
    /// actor answers inside the 600ms this step holds the window open.
    /// The shared client cannot serve this claim at all — a background
    /// call that ANSWERS also clears `darkUntil`, which would hand the
    /// ladder its second attempt for free and pass with the fix gone.
    private func retryDoesNotAnswerFromAProvenSilence() async {
        guard let cfg = TestConfigFactory.throwaway(name: "TE-Ladder-\(runTag)") else {
            fail("factory produced no config")
            return
        }
        tracked.append(cfg)

        // A client of this step's OWN. The window, the counter and the
        // discard are all private state on ONE client, and the app's
        // shared one is answering calls for the whole suite while this
        // step runs — the gate polls it, every reload reads it. Three
        // versions of this step measured that shared client and all
        // three were wrong in a different direction: a duration with a
        // 200ms margin, a counter a real answer zeroes, and then a
        // monotonic counter a CONCURRENT caller inflates by getting
        // itself spared inside the 600ms this step holds the window
        // open. The contamination is not only in the reading either —
        // a background call that ANSWERS clears `darkUntil`, which
        // would hand the ladder its second attempt for free and make
        // the whole claim pass with the fix reverted.
        //
        // A fresh instance ends all of it. It reaches the same mach
        // service, so the store really lands in the real vault and the
        // read really asks it; nothing else in the app holds this
        // object, so nothing else can arm, clear or count on it.
        let client = TunnelVaultClient()
        client.armProvenSilenceForTesting()
        guard client.hasProvenSilence else {
            fail("the arrangement never armed a proven silence — nothing below would be measured")
            return
        }

        let sparedBefore = client.darkWindowAnswersTotal
        let outcome = await client.store(cfg, attempts: 3)
        let spared = client.darkWindowAnswersTotal - sparedBefore

        // The environment exit comes FIRST, and it is discriminated by
        // the pair rather than by the outcome alone. One spared call
        // means the discard ran and the ladder really asked; if it then
        // answers `.unreachable`, the vault was away for the attempts
        // this step cannot control, and calling that a product failure
        // would break the suite-wide doctrine stated at the top of this
        // file. The red for a reverted discard is carried entirely by
        // `spared != 1`, so nothing is softened by taking this exit.
        if outcome == .unreachable && spared == 1 {
            skip("environment: the vault never answered the ladder's real attempts")
            return
        }
        check(outcome == .done,
              "the ladder reached the extension through a proven silence — outcome=\(outcome.label), expected done")
        // The arrangement's own proof, and it is a COUNT rather than a
        // duration. An earlier version read the wall clock against the
        // 0.6s backoff, which left about 200ms between "the window was
        // in the way" and "the window had already lapsed and the first
        // attempt simply answered" — a margin one scheduling slip
        // closes, on a step whose whole job is to notice a reverted
        // fix. The counter cannot be blurred: with the discard in place
        // exactly the first attempt is answered from the window, and
        // with it reverted all three are.
        check(spared == 1,
              "and exactly one attempt was answered from the window before it asked for real — spared=\(spared),"
              + " expected 1 (more than one would mean the ladder answered itself from the window)")

        // The DELETE ladder gets its own window, because it is the one
        // the field bug came from. `entryGoesFirst` and the payload
        // delete are what reported "the tunnel cannot be deleted right
        // now" over a vault that was merely respawning, and the
        // production doc credits that catch by name — yet the discard
        // has three call sites and only the store's was witnessed here.
        // Two of three is not coverage; it is a coin toss about which
        // one a future edit breaks silently.
        client.armProvenSilenceForTesting()
        guard client.hasProvenSilence else {
            fail("the arrangement never armed a second proven silence — the delete ladder below is unmeasured")
            return
        }
        let sparedBeforeDelete = client.darkWindowAnswersTotal
        let deleted = await client.delete(id: cfg.id, attempts: 3)
        let sparedByDelete = client.darkWindowAnswersTotal - sparedBeforeDelete
        if deleted == .unreachable && sparedByDelete == 1 {
            skip("environment: the vault never answered the delete ladder's real attempts")
            return
        }
        check(deleted == .done,
              "the delete ladder reached the extension through a proven silence too — outcome=\(deleted.label), expected done")
        check(sparedByDelete == 1,
              "sparing exactly its first attempt, like the store's — spared=\(sparedByDelete), expected 1")
        // Read LAST, and it now proves both ladders at once: the store
        // really landed a payload in the real vault and the delete
        // really took it away again. `.missing` here is the delete's
        // proof, not an absence to worry about — and it is what says
        // neither `.done` came from a cache.
        switch await client.read(id: cfg.id) {
        case .missing:
            check(true, "and the daemon really did both — the payload landed and was then taken away")
        case .config, .undecodable:
            check(false, "the delete answered done over a payload the vault still holds")
        case .unreachable:
            // Not a product failure. The vault answering the ladder and
            // then going dark for this read is an environment event, and
            // calling it "the vault does not hold the payload" would be
            // a sentence the step cannot support.
            skip("environment: the vault went dark before the landing could be re-read")
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
        // Through the kit rather than `!= .done`: a silence is not a
        // failure. A delete whose reply was lost has still landed, and
        // reporting it as "lingers in the vault" sends a reader looking
        // for a payload that is not there.
        switch await verifiedDelete(cfg.id) {
        case .swept, .sweptOnReread:
            break
        case .stillPresent:
            log("cleanup: corrupt payload is still in the vault after a verified sweep — \(name)", .warn)
        case .unverified:
            log("cleanup: corrupt payload sweep unverified — the vault went dark, so whether \(name) is gone was never observed", .warn)
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
        // The one place in this file where a delete's answer DECIDES
        // something, so collapsing it was the most expensive of the
        // three: on any non-`.done` the entry was kept, and for a
        // SILENT vault that is a coin flip. If the delete had in fact
        // landed, keeping the entry manufactures the payload-less pair
        // this whole campaign exists to close — deliberately, in a
        // cleanup, under a sentence that said "delete failed".
        //
        // Told apart, each answer earns its own decision. `.stillPresent`
        // keeps the entry because the payload is provably there and the
        // entry is what makes it reachable. `.unverified` keeps it too —
        // the same choice, but now for a stated reason and with the risk
        // named rather than hidden, because removing an entry over a
        // payload that may have survived strands it for good while the
        // reverse is repaired by the next reload.
        switch await verifiedDelete(id) {
        case .swept, .sweptOnReread:
            break
        case .stillPresent:
            log("cleanup: the payload is still in the vault, so the NE entry stays — it is what keeps the custody row reachable", .warn)
            return
        case .unverified:
            log("cleanup: the vault went dark, so the payload's fate was never observed — the NE entry stays; if the delete "
                + "did land, the next reload hides that entry rather than repairing it", .warn)
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
        // What the LIVE app minted while this workflow ran goes first,
        // and it goes through `remove()`.
        //
        // These payloads sit in the user's real vault, so a reconcile
        // pass firing mid-run reads them as payloads the system lost
        // and mints real entries for them. That is the app doing its
        // job, not a defect — but deleting the payload underneath such
        // a row manufactures the exact residue this campaign exists to
        // close: an entry with no secret, which the ownership boundary
        // files as another local user's, invisible to the list and
        // undeletable through the app. The teardown net sweeps them
        // afterwards, and afterwards is the wrong time to be right: the
        // suite must not create that class at all, not even for the
        // seconds until its own net runs.
        //
        // Cheap where it does not apply and correct where it does.
        // `remove()` empties both stores in the order the row's own
        // payload decides, and the delete below is idempotent over what
        // it already took (Upsert Semantics proves that), so an
        // ordinary run — where nothing materialized — pays nothing.
        // A row whose removal REFUSED keeps its payload: leaving the
        // pair intact is the whole point, since deleting the secret out
        // from under an entry that is still in System Settings is the
        // residue this loop exists to prevent. So the refusals are
        // collected and the delete pass below skips them, and the
        // absence check reports them as what they are.
        //
        // And the REMOVALS stop at the first vault that will not
        // answer, the same dark-door rule the throwaway net already
        // applies: one unreachable read is a symptom, a run of them is
        // a door that is shut, and each further row would spend a read
        // ladder — plus a delete ladder behind it, on any row whose
        // read did answer — proving it again.
        //
        // The SCAN does not stop, and the difference is the whole
        // correctness of the door. What the break used to skip was the
        // listing check as well, so every row after it stayed unknown
        // to `keptPaired` and the delete pass below took its payload —
        // re-creating, on a vault that recovers a moment later, the
        // payload-less entry this loop exists to prevent.
        // One set decides which payloads the pass below must not touch;
        // the counters beside it keep the REASONS apart, because they
        // are different facts and the closing line reports them to
        // somebody reading a red. A refusal already has its own `fail`;
        // a row another removal owns is a race this step chose not to
        // fight; a row the dark door reached was never tried at all.
        var minted = 0
        var removed = 0
        var keptPaired: Set<UUID> = []
        var keptRefused = 0
        var keptRaced = 0
        var keptUntried = 0
        var darkDoor = false
        for cfg in tracked {
            guard let row = tunnels.tunnels.first(where: { $0.id == cfg.id }) else { continue }
            minted += 1
            guard !darkDoor else {
                keptPaired.insert(cfg.id)
                keptUntried += 1
                continue
            }
            do {
                try await tunnels.remove(tunnel: row)
            } catch {
                keptPaired.insert(cfg.id)
                keptRefused += 1
                if case TunnelManagementError.vaultUnavailable = error { darkDoor = true }
                fail("a live restore minted '\(cfg.name)' into the list and the removal refused — its entry and its payload are both left standing, which is the safe pair — \(error.localizedDescription)")
                continue
            }
            // "Did not throw" is not "is gone". `remove()` answers
            // silently for an id already being removed — a deliberate
            // no-op, and its row is still listed with its payload still
            // needed. The list is what says whether this row left, so
            // the list is what is read.
            if tunnels.tunnels.contains(where: { $0.id == cfg.id }) {
                keptPaired.insert(cfg.id)
                keptRaced += 1
                log("'\(cfg.name)' is still listed after its removal answered — another removal owns it, so its payload stays beside the entry", .warn)
            } else {
                removed += 1
            }
        }
        if minted > 0 {
            log("a live restore had already minted \(minted) of these throwaways into the list — \(removed) removed through the production path before any payload was touched"
                + (darkDoor ? ", and the loop stopped at a vault that would not answer" : ""),
                keptPaired.isEmpty ? .warn : .error)
        }
        // Same patience for both stashes: a vault respawn window does
        // not care which client wrote the payload, and the impatient
        // single shot the tracked configs used to get was the one that
        // left them behind when the door was mid-restart.
        for id in rawIds {
            await vault.delete(id: id, attempts: 3)
        }
        for cfg in tracked where !keptPaired.contains(cfg.id) {
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
        // The tail names the reasons apart, and it has to: a row another
        // removal owns usually has its payload taken by that owner while
        // this step is still reading, so the absence check passes and a
        // clause blaming a refusal would print green over a refusal that
        // never happened. When the owner has not finished, the same
        // clause is the only account of why a documented-safe outcome is
        // printing red.
        var kept: [String] = []
        if keptRefused > 0 { kept.append("\(keptRefused) after a refused removal") }
        if keptRaced > 0 { kept.append("\(keptRaced) under a removal another caller owns") }
        if keptUntried > 0 { kept.append("\(keptUntried) never tried, behind a vault that stopped answering") }
        check(gone == tracked.count && rawGone == rawIds.count,
              "all \(tracked.count) throwaways and \(rawIds.count) raw plants read back .missing (\(gone)+\(rawGone) confirmed)"
              + (kept.isEmpty ? "" : " — \(keptPaired.count) payload(s) left beside their entry on purpose: \(kept.joined(separator: ", "))"))
    }

    private func noMaterialization() async {
        // What this step still owns, now that `Delete Proof` removes a
        // materialized row before it touches any payload: the list is
        // clean at the END, and nothing arrived in the gap between the
        // two steps. That gap is real rather than theoretical — the
        // removals above broadcast configuration changes of their own,
        // and the pass they wake reads whatever payloads are still in
        // the vault at that moment.
        //
        // The in-memory list is the sample, deliberately unforced. A
        // reload now could not mint anything (the payloads are gone)
        // but it WOULD hide a row minted earlier: ingest files a
        // payload-less row under another user. The unreloaded list is
        // therefore the only surface that can still show the damage.
        // The suite's own steps do not reshape it — they touch the
        // vault, which posts no configuration-change notification —
        // but one outside reshaper does: a foreground return mid-run
        // schedules a reload. Accepted as a limit, and the reason this
        // is no longer the only line of defence.
        let ids = Set(tracked.map(\.id))
        let materialized = tunnels.tunnels.filter { ids.contains($0.id) }
        check(materialized.isEmpty,
              "no throwaway is left in the tunnel list — a row here would be one a restore minted after the delete step swept the list, with its payload already gone (\(materialized.count) found)")
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
