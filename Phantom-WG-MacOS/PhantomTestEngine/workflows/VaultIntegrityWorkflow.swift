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
            // These two run LAST, on a vault holding only the door
            // configs: they are the only steps that trigger a reconcile
            // (via add) — and the visibility gate drives a full reload
            // besides. Keeping them after Delete Proof stops those
            // passes from materialising the bulk throwaways this run
            // had stored.
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
    private let runTag = String(UUID().uuidString.prefix(8))

    // MARK: - Steps

    private func pingReady() async {
        // Registered from the first step, before anything is planted:
        // the stashes are read when the net RUNS, so it sweeps
        // whatever the run got as far as storing. Delete Proof stays
        // the owner and keeps earning its absence proof on the normal
        // path — by the time this runs there, both stashes read
        // `.missing` already and it reports a clean zero.
        onTeardown("vault throwaways") { [weak self] in
            guard let self else { return }
            let ids = self.tracked.map(\.id) + self.rawIds
            guard !ids.isEmpty else {
                self.log("teardown: nothing was planted")
                return
            }
            // Only what is still there is swept, and only a delete
            // that answered true counts — deleting an id the vault no
            // longer holds also answers true, which is why the read
            // comes first and the count means "was there, now gone".
            // An `.unreachable` read is neither: it proves nothing
            // about that id and it means the next fifteen will each
            // burn their own transport timeout. One is a symptom, a
            // whole run of them is a dark door, so the loop stops and
            // says what it could not check instead of spending
            // minutes discovering the same thing sixteen times.
            var swept = 0
            var stuck = 0
            var unchecked = 0
            var index = 0
            for id in ids {
                index += 1
                switch await self.vault.read(id: id) {
                case .missing:
                    continue
                case .unreachable:
                    unchecked = ids.count - index + 1
                    self.log("teardown: vault dark — swept \(swept), still present \(stuck), \(unchecked) of \(ids.count) left unchecked", .error)
                    return
                case .config, .undecodable:
                    if await self.vault.delete(id: id, attempts: 3) { swept += 1 } else { stuck += 1 }
                }
            }
            if swept == 0 && stuck == 0 {
                self.log("teardown: all \(ids.count) planted payload(s) already gone")
            } else {
                self.log("teardown: swept \(swept), still present \(stuck), of \(ids.count) planted", stuck > 0 ? .error : .warn)
            }
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
            guard await vault.store(cfg) else {
                fail("store refused: \(cfg.name)")
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
        guard await vault.store(v2) else {
            fail("rewrite store refused")
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
        guard await vault.store(twin) else {
            fail("twin store refused")
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
            if !(await vault.store(cfg)) { fail("store refused: \(cfg.name)") }
            expected.insert(cfg.id)
        }
        await verifyExactSet(expected, "after storing 10")

        for (index, cfg) in pool.enumerated() where index % 2 == 0 {
            if !(await vault.delete(id: cfg.id)) { fail("delete refused: \(cfg.name)") }
            expected.remove(cfg.id)
        }
        await verifyExactSet(expected, "after deleting 5")

        for (index, cfg) in pool.enumerated() where index % 2 == 0 {
            if !(await vault.store(cfg)) { fail("re-store refused: \(cfg.name)") }
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
            guard let self else { return }
            var notes: [String] = []
            var stuck = false
            let payloadPresent: Bool
            if case .missing = await self.vault.read(id: cfg.id) {
                payloadPresent = false
            } else {
                payloadPresent = true
            }
            if let listed = self.tunnel(named: name) {
                do {
                    try await self.tunnels.remove(tunnel: listed)
                    notes.append("entry removed")
                } catch {
                    notes.append("entry still listed (\(error.localizedDescription))")
                    stuck = true
                }
            } else if payloadPresent {
                // Not listed, but the bytes say the step never swept:
                // the row is hidden rather than gone, so the kept
                // container is the only way to take the entry down.
                if (try? await base.tunnelProvider.removePreferences()) == nil {
                    notes.append("hidden NE entry removal failed — check System Settings > VPN")
                    stuck = true
                } else {
                    notes.append("hidden NE entry removed")
                }
            }
            // `remove()` above deletes the payload itself, so this is
            // a sweep of whatever is left rather than a second delete.
            if case .missing = await self.vault.read(id: cfg.id) {
                // Nothing left.
            } else if await self.vault.delete(id: cfg.id, attempts: 3) {
                notes.append("corrupt payload swept")
            } else {
                notes.append("corrupt payload still present")
                stuck = true
            }
            self.log("teardown: corruption base — \(notes.isEmpty ? "already clean" : notes.joined(separator: ", "))",
                     stuck ? .error : (notes.isEmpty ? .info : .warn))
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
        if !(await vault.delete(id: cfg.id, attempts: 3)) {
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
            // A payload still present means the step's own cleanup
            // never completed, and that is also the only reliable
            // signal that the NE entry is still there: asking the
            // manager is no good here (the row can be hidden), and
            // calling removePreferences on an entry the step already
            // removed would answer with an error we would then report
            // as residue that does not exist.
            let payloadPresent: Bool
            if case .missing = await self.vault.read(id: cfg.id) {
                payloadPresent = false
            } else {
                payloadPresent = true
            }
            if payloadPresent {
                if await self.vault.delete(id: cfg.id, attempts: 3) {
                    notes.append("corrupt payload swept")
                } else {
                    notes.append("corrupt payload still present")
                    stuck = true
                }
                if (try? await container.tunnelProvider.removePreferences()) == nil {
                    notes.append("NE entry removal failed — check System Settings > VPN")
                    stuck = true
                } else {
                    notes.append("NE entry removed")
                }
            } else if self.tunnels.tunnels.contains(where: { $0.id == cfg.id }) {
                // Payload gone but the row survived it: the step got
                // half way. Take the entry down too.
                if (try? await container.tunnelProvider.removePreferences()) == nil {
                    notes.append("NE entry removal failed — check System Settings > VPN")
                    stuck = true
                } else {
                    notes.append("NE entry removed")
                }
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
        guard await vault.delete(id: id, attempts: 3) else {
            log("cleanup: vault delete failed — NE entry left in place so the custody row stays reachable", .warn)
            return
        }
        if (try? await container.tunnelProvider.removePreferences()) == nil {
            log("cleanup: NE entry removal failed — an unbacked entry may linger in System Settings > VPN", .warn)
        } else {
            // Prune the hidden container deterministically: list
            // hygiene must not depend on the debounced refresh being
            // alive (an uninstall latch silences it for the process).
            await tunnels.refresh()
        }
    }

    /// The upsert's contract, pinned from the caller's side. Three
    /// claims, each load-bearing: a valid store over an id holding
    /// corrupt bytes heals the slot in place (the user's re-import
    /// recovery — the one cell of the corrupt/valid matrix no other
    /// step reaches); storing the same payload twice changes nothing
    /// (the client's retry ladder re-stores after a timeout that hid a
    /// landed write); and deleting an absent or already-deleted id
    /// answers true (remove()'s retry path wedges the tunnel as
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
        guard await vault.store(cfg) else {
            fail("valid store over a corrupt slot refused — heal-in-place broken")
            return
        }
        if case .config(let healed) = await vault.read(id: cfg.id) {
            check(healed == cfg, "valid store over corrupt bytes healed the slot in place")
        } else {
            fail("healed slot did not read back as a config")
        }

        guard await vault.store(cfg) else {
            fail("second identical store refused — a retry after a timed-out-but-landed write would not be harmless")
            return
        }
        if case .config(let again) = await vault.read(id: cfg.id) {
            check(again == cfg, "storing the same payload twice reads back unchanged")
        } else {
            fail("double-stored slot did not read back as a config")
        }

        check(await vault.delete(id: UUID()), "deleting a never-stored id answers true")
        guard let twice = TestConfigFactory.throwaway(name: "TE-DelTwice-\(runTag)") else {
            fail("factory produced no config")
            return
        }
        tracked.append(twice)
        guard await vault.store(twice) else {
            fail("store refused: \(twice.name)")
            return
        }
        check(await vault.delete(id: twice.id), "first delete answers true")
        check(await vault.delete(id: twice.id), "second delete of the same id answers true")
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
