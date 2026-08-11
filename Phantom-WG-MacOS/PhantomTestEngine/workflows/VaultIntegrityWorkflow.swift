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
        switch await vault.ping() {
        case .ready(let payloads, let identity):
            log("vault ready — identity=\(identity) payloads=\(payloads)", .ok)
        case .doorFailed(let identity):
            fail("extension answered but the keychain door failed — identity=\(identity)")
        case .unreachable:
            fail("vault unreachable")
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
                fail("\(cfg.name): read unreachable after store")
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
            fail("read unreachable after rewrite")
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
        var bothReadable = true
        for id in [base.id, twin.id] {
            if case .config = await vault.read(id: id) { continue }
            bothReadable = false
        }
        check(bothReadable && base.id != twin.id,
              "two payloads share name \"\(base.name)\" under distinct ids — the vault keys on id, name uniqueness stays TunnelsManager's duty")
    }

    private func stressInterleave() async {
        guard case .configs(let baseline) = await vault.readAll() else {
            fail("readAll unreachable at baseline")
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
    /// the same as one that is truly absent — otherwise reconcile,
    /// which trusts "missing" as "the vault owns nothing here", would
    /// drop a real entry and orphan its secret. read(id) reports a
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
            fail("vault unreachable")
            return
        }
        let absent = await vault.read(id: absentId)
        check(label(corrupt) != label(absent),
              "undecodable distinct from absent — corrupt=\(label(corrupt)) absent=\(label(absent))")
    }

    /// An undecodable payload must not be silently conflated with an
    /// absent one across the read surfaces. read(id) is the surface
    /// reconcile trusts for its drop decision, so it must surface the
    /// payload as `.undecodable`; readAll legitimately excludes it from
    /// its decodable-config list (reconcile does not drop off readAll),
    /// so the invariant is "read(id) surfaces it", not "both list it".
    private func undecodableAgreement() async {
        guard let id = rawIds.last else {
            skip("no corrupt payload planted")
            return
        }
        let byId = await vault.read(id: id)
        guard case .configs(let all) = await vault.readAll() else {
            fail("readAll unreachable")
            return
        }
        let inReadAll = all.contains { $0.id == id }
        let hiddenById = label(byId) == "missing"
        check(!(hiddenById && !inReadAll),
              "read(id) surfaces undecodable, not conflated with absent — read(id)=\(label(byId)), readAll excludes it (inReadAll=\(inReadAll))")
    }

    /// Corrupt a real tunnel's payload in place, then reconcile. The
    /// entry — and the secret bytes — must survive: a broken payload is
    /// a custody problem to surface, not a licence to delete the entry.
    /// reconcile's drop path consults read(id), which reports
    /// `.undecodable` rather than `.missing`, so the entry is preserved;
    /// this guards against a regression that would orphan the secret.
    private func corruptionSurvival() async {
        let name = "TE-Corrupt-\(runTag)"
        guard let cfg = TestConfigFactory.throwaway(name: name) else {
            fail("factory produced no config")
            return
        }
        guard (try? await tunnels.add(config: cfg)) != nil else {
            fail("add failed for the corruption base")
            return
        }
        guard await vaultRaw.storeRaw(Data("corrupt".utf8), id: cfg.id) else {
            fail("raw corrupt store refused")
            return
        }
        _ = await tunnels.reconcileFromVault()
        let survived = tunnel(named: name) != nil
        check(survived, survived
            ? "entry survived a corrupted payload through reconcile"
            : "entry DROPPED after payload corruption — secret orphaned (reconcile read undecodable as absent)")
        if let t = tunnel(named: name) {
            try? await tunnels.remove(tunnel: t)
        }
        await vault.delete(id: cfg.id, attempts: 3)
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
            : "tunnel VANISHED from the list after a reload — the ownership filter took an undecodable own payload for another user's entry")
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
        for id in rawIds {
            await vault.delete(id: id, attempts: 3)
        }
        guard !tracked.isEmpty else {
            skip("nothing was stored")
            return
        }
        for cfg in tracked {
            await vault.delete(id: cfg.id)
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
        let ids = Set(tracked.map(\.id))
        let materialized = tunnels.tunnels.filter { ids.contains($0.id) }
        check(materialized.isEmpty,
              "no throwaway materialized into the tunnel list (\(materialized.count) found)")
        check(tunnel(named: TestContext.ghostName) != nil && tunnel(named: TestContext.wireGuardName) != nil,
              "door configs intact")
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
            fail("readAll unreachable \(label)")
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
