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
    private var tracked: [TunnelConfig] = []
    /// Ids written as RAW (undecodable) bytes via the injection client;
    /// swept alongside `tracked` so no corrupt payload is left behind.
    private var rawIds: [UUID] = []
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

// MARK: - Verified sweep kit — the three-valued reads,
// re-read-verified deletes/removals, the fresh-list probe and the
// corruption net body they serve. Same file, so `private` members
// stay reachable from the class; out of the class body so the
// type-length ruler keeps measuring the workflow's own steps.
extension VaultIntegrityWorkflow {
    /// One vault read, kept three-valued. `.unreachable` is neither
    /// presence nor absence, and the nets below decide differently on
    /// each: collapsing it into "present" let their arms print
    /// verified-sounding verdicts — "still present", "swept" — over a
    /// reading that verified nothing.
    private enum PayloadReading { case present, missing, unreachable }

    /// Three attempts, spaced: waking the vault extension usually
    /// costs the first one, and every sweep decision downstream rides
    /// this answer — a single lost 5s race must not convert a
    /// self-healing teardown into do-nothing residue. `.present` is
    /// presence only, decodable and corrupt bytes alike, which is why
    /// no arm below calls what it swept "corrupt": presence was
    /// observed, the bytes' nature was not.
    private func readPayloadState(_ id: UUID) async -> PayloadReading {
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
    private enum SweepVerdict { case swept, sweptOnReread, stillPresent, unverified }

    private func verifiedDelete(_ id: UUID) async -> SweepVerdict {
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
    private enum EntryRemoval { case removed, alreadyGone, failed, unverified }

    private func verifiedEntryRemoval(id: UUID, via provider: TunnelProviding) async -> EntryRemoval {
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
    private func probeHiddenSurvivor(id: UUID) async -> (notes: [String], stuck: Bool) {
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
    /// `.missing` identifies its half on its own, and only it acts. The
    /// `.present` arm therefore REPORTS rather than resolves; separating
    /// the two worlds needs a fresh system-list read and a second look
    /// after the sweep, which is a package of its own.
    private func resolveFailedRemove(_ listed: TunnelContainer, id: UUID, error: Error) async -> (notes: [String], stuck: Bool) {
        switch await readPayloadState(id) {
        case .present:
            // This arm deliberately does NOT act, and it no longer
            // claims to know why it is not acting.
            //
            // Sweeping a payload out from under a LISTED entry would
            // hide the row on the next reload — the strand every arm
            // here refuses — and `.present` can still be that case. But
            // it can equally be an entry-first removal whose payload
            // delete was refused, where the bytes are an orphan and
            // keeping them is the wrong answer. The payload alone
            // cannot separate the two, so the residue is REPORTED and
            // the run is flagged rather than guessed at.
            //
            // Clearing it properly needs a fresh system-list read and,
            // because `remove()` has just scheduled a restore that can
            // mint an entry into the window, a second look AFTER the
            // sweep. That is its own package, not a line in this one.
            return (["payload present, entry unverified — residue kept for inspection (\(error.localizedDescription))"], true)
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
    private func sweepCorruptionBase(_ base: TunnelContainer, id: UUID, name: String) async {
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
    private func sweepThrowaways() async {
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
