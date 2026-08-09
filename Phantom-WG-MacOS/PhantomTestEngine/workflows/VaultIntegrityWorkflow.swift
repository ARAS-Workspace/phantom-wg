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
            WorkflowStep("Delete Proof", deleteProof),
            WorkflowStep("No Materialization", noMaterialization),
            // Runs LAST, on a vault holding only the door configs: this
            // is the only step that triggers a reconcile (via add), and
            // keeping it after Delete Proof stops that reconcile from
            // materialising the bulk throwaways this run had stored.
            WorkflowStep("Entry Survives Corruption (Reconcile)", corruptionSurvival),
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
        check(gone == tracked.count, "all \(tracked.count) throwaways read back .missing (\(gone) confirmed)")
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
