// ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
// ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
// ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
// ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
// ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
// ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
//
// Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
// Licensed under AGPL-3.0 - see LICENSE file for details
// WireGuard® is a registered trademark of Jason A. Donenfeld.
//
// Vault Integrity
//
// A stressed data-integrity pass over the vault XPC surface, server-free
// and deterministic. Throwaway configs from `TestConfigFactory`; every
// payload stored through that path is swept before the run ends.
//
// The user's own tunnel list may legitimately NOTICE this run, and that is
// not a defect on either side: these payloads live in the REAL vault, so a
// reconcile firing mid-run restores them exactly as it would any payload
// the system had lost. What the suite owes back is the ORDER — a row is
// removed through `remove()` before any payload is deleted, so no entry is
// ever left without its secret — and a step that proves the list is clean
// when the pass is over.
//
// Three failure gates it watches throughout: duplicate entries, stale
// reads after a rewrite, and `read(id)` disagreeing with `readAll`.
//
// Scenarios, in four groups. `steps` is the registry; these are the
// questions each group asks:
//
//   1. The vault surface (this file)
//      Ping, round-trip fidelity, rewrite, duty separation between two
//      ids sharing a name, an interleaved stress round, a ladder that
//      will not answer itself from a proven silence, undecodable
//      payloads reported distinctly and not conflated between the two
//      read paths, upsert and delete idempotence, and a proof that
//      nothing this run stored is still materialised at the end.
//
//   2. Custody reads (`+CustodyReads.swift`)
//      What the app believes about a payload at the MOMENT it acts on it,
//      as opposed to what a bulk answer said earlier. Purge, and the
//      reconcile family.
//
//   3. Custody writes (`+CustodyWrites.swift`)
//      Which store a removal empties first, what a removal that only
//      half finishes leaves behind, and what an uninstall's teardown may
//      not have undone behind its back.
//
//   4. The two corruption steps, which run LAST
//      They are the only steps whose reconcile reads the real vault, and
//      the visibility gate drives a full reload besides. Kept after the
//      delete proof so those passes cannot materialise the bulk
//      throwaways this run had stored. The custody-read AND custody-write
//      steps reconcile too, but every one of them over a FABRICATED vault,
//      so no throwaway
//      of this run is ever a candidate for them.
//
// Group 2 is registered BEFORE groups 3 and 4 so the "run last" contract
// of the corruption pair keeps meaning what it says.
//
// The planted ledgers (`tracked`, `rawIds`) are written and read by the
// steps of this workflow alone, and the sweep is the last reader of both.
// That coupling is why `sweepThrowaways`
// stayed in this workflow while the rest of the kit moved to the base: a
// net that reads these two ledgers has no meaning on a workflow that
// planted something else.

#if DEBUG
import Foundation

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
            WorkflowStep("A Purge Never Touches A Listed Tunnel's Payload", purgeSparesAListedPayload),
            WorkflowStep("Reconcile Proves A Payload Before Minting", reconcileProvesAPayloadBeforeMinting),
            WorkflowStep("Reconcile Marks Its Candidates Before It Probes", reconcileMarksItsCandidateBeforeItAsks),
            WorkflowStep("Reconcile Reads The List Again After Probing", reconcileReadsTheListAgainAfterProbing),
            WorkflowStep("Reconcile Guards The Name It Is About To Write", reconcileGuardsTheNameItIsAboutToWrite),
            WorkflowStep("Reconcile Refuses A Payload It Cannot Trust", reconcileRefusesAPayloadItCannotTrust),
            WorkflowStep("A Dark Vault Stops The Minting Where It Went Dark", reconcileStopsMintingWhenTheVaultGoesDark),
            WorkflowStep("A Restore Puts The Tunnel Back As An Entry", aRestorePutsTheTunnelBackAsAnEntry),
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
            WorkflowStep("The Uninstall's Removal Is Not Undone By The Restore",
                         theUninstallsRemovalIsNotUndoneByTheRestore),
            WorkflowStep("Entry Survives Corruption (Reconcile)", corruptionSurvival),
            WorkflowStep("Undecodable Payload Stays Listed (Reload)", custodyVisibility),
        ]
    }

    private(set) var tracked: [TunnelConfig] = []
    private(set) var rawIds: [UUID] = []
    let runTag = String(UUID().uuidString.prefix(8))

    // MARK: - Steps

    private func pingReady() async {
        onTeardown("vault throwaways") { [weak self] in
            await self?.sweepThrowaways()
        }
        switch await vault.ping() {
        case .ready(let payloads, let identity):
            log("vault ready — identity=\(identity) payloads=\(payloads)", .ok)
        case .doorFailed(let identity):
            fail("extension answered but the keychain door failed — identity=\(identity)")
        case .unreachable:
            skip("environment: vault unreachable")
        }
    }

    private func retryDoesNotAnswerFromAProvenSilence() async {
        guard let cfg = TestConfigFactory.throwaway(name: "TE-Ladder-\(runTag)") else {
            fail("factory produced no config")
            return
        }
        tracked.append(cfg)

        let client = TunnelVaultClient()
        client.armProvenSilenceForTesting()
        guard client.hasProvenSilence else {
            fail("the arrangement never armed a proven silence — nothing below would be measured")
            return
        }

        let sparedBefore = client.darkWindowAnswersTotal
        let outcome = await client.store(cfg, attempts: 3)
        let spared = client.darkWindowAnswersTotal - sparedBefore

        if outcome == .unreachable && spared == 1 {
            skip("environment: the vault never answered the ladder's real attempts")
            return
        }
        check(outcome == .done,
              "the ladder reached the extension through a proven silence — outcome=\(outcome.label), expected done")
        check(spared == 1,
              "and exactly one attempt was answered from the window before it asked for real — spared=\(spared),"
              + " expected 1 (more than one would mean the ladder answered itself from the window)")

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
        switch await client.read(id: cfg.id) {
        case .missing:
            check(true, "and the daemon really did both — the payload landed and was then taken away")
        case .config, .undecodable:
            check(false, "the delete answered done over a payload the vault still holds")
        case .unreachable:
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

    private func undecodableRead() async {
        let corruptId = UUID()
        let absentId = UUID()
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
        guard case .undecodable = byId else {
            fail("read(id) did not surface the planted payload as .undecodable — got \(label(byId))")
            return
        }
        check(!inReadAll, "read(id) surfaces undecodable, not conflated with absent — read(id)=\(label(byId)), readAll's decoded answer excludes it (inReadAll=\(inReadAll))")
    }

    private func corruptionSurvival() async {
        let name = "TE-Corrupt-\(runTag)"
        guard let cfg = TestConfigFactory.throwaway(name: name) else {
            fail("factory produced no config")
            return
        }
        guard let base = try? await tunnels.add(config: cfg) else {
            fail("add failed for the corruption base")
            return
        }
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
        if let t = tunnel(named: name) {
            do { try await tunnels.remove(tunnel: t) } catch {
                log("cleanup: entry remove failed — \(name) lingers in the list (\(error.localizedDescription))", .warn)
            }
        }
        switch await verifiedDelete(cfg.id) {
        case .swept, .sweptOnReread:
            break
        case .stillPresent:
            log("cleanup: corrupt payload is still in the vault after a verified sweep — \(name)", .warn)
        case .unverified:
            log("cleanup: corrupt payload sweep unverified — the vault went dark, so whether \(name) is gone was never observed", .warn)
        }
    }

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
        onTeardown("visibility base") { [weak self] in
            guard let self else { return }
            var notes: [String] = []
            var stuck = false
            switch await self.readPayloadState(cfg.id) {
            case .present:
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

    private func cleanupVisibilityBase(_ container: TunnelContainer, _ id: UUID) async {
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
            await tunnels.prune()
        }
    }

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
        guard !tracked.isEmpty || !rawIds.isEmpty else {
            skip("nothing was stored")
            return
        }
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
        var rawGone = 0
        for id in rawIds {
            if case .missing = await vault.read(id: id) { rawGone += 1 }
        }
        var kept: [String] = []
        if keptRefused > 0 { kept.append("\(keptRefused) after a refused removal") }
        if keptRaced > 0 { kept.append("\(keptRaced) under a removal another caller owns") }
        if keptUntried > 0 { kept.append("\(keptUntried) never tried, behind a vault that stopped answering") }
        check(gone == tracked.count && rawGone == rawIds.count,
              "all \(tracked.count) throwaways and \(rawIds.count) raw plants read back .missing (\(gone)+\(rawGone) confirmed)"
              + (kept.isEmpty ? "" : " — \(keptPaired.count) payload(s) left beside their entry on purpose: \(kept.joined(separator: ", "))"))
    }

    private func noMaterialization() async {
        let ids = Set(tracked.map(\.id))
        let materialized = tunnels.tunnels.filter { ids.contains($0.id) }
        check(materialized.isEmpty,
              "no throwaway is left in the tunnel list — a row here would be one a restore minted after the delete step swept the list, with its payload already gone (\(materialized.count) found)")
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
