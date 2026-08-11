#if DEBUG
import Foundation
import NetworkExtension

/// Minimal `TunnelProviding` stand-in for slot/isolation stress. The
/// system cannot hand the harness another user's live session, but a
/// synthetic provider whose id the vault does not back IS one, as far
/// as every classifier and filter in the app can tell — ownership is
/// decided by the owner-scoped vault, never by who minted the object.
/// Records what the code under test does to it (arming, saves, starts)
/// so the steps can assert the negative space: what must NOT happen.
final class FakeSlotProvider: TunnelProviding {
    var localizedDescription: String?
    var isEnabled = false
    private(set) var identity: TunnelIdentity?
    var tunnelIdentity: TunnelIdentity? { identity }
    func configure(with identity: TunnelIdentity) { self.identity = identity }
    var isOnDemandEnabled = false
    var onDemandRules: [NEOnDemandRule]?
    var connectionStatus: NEVPNStatus
    private(set) var saveCount = 0
    private(set) var startCount = 0

    init(name: String?, identity: TunnelIdentity?, status: NEVPNStatus) {
        self.localizedDescription = name
        self.identity = identity
        self.connectionStatus = status
    }

    func startTunnel() throws { startCount += 1 }
    func stopTunnel() {}
    func sendProviderMessage(_ data: Data, responseHandler: @escaping @Sendable (Data?) -> Void) throws {
        responseHandler(nil)
    }
    func savePreferences(completion: @escaping @Sendable (Error?) -> Void) {
        saveCount += 1
        completion(nil)
    }
    func loadPreferences(completion: @escaping @Sendable (Error?) -> Void) { completion(nil) }
    func removePreferences(completion: @escaping @Sendable (Error?) -> Void) { completion(nil) }
    func matchesNotification(_ notification: Notification) -> Bool { false }
    func fetchLastDisconnectError(completion: @escaping @Sendable (Error?) -> Void) { completion(nil) }
}

struct FakeSlotFactory: TunnelProviderFactory {
    let canned: [TunnelProviding]
    func makeProvider() -> TunnelProviding {
        FakeSlotProvider(name: nil, identity: nil, status: .invalid)
    }
    func loadAllFromPreferences() async throws -> [TunnelProviding] { canned }
}

/// Cross-user isolation, stressed on a single identity: synthetic
/// foreign providers against the REAL vault. The classifier's foreign
/// verdict rests on the daemon answering `.missing` for ids this user
/// does not own — exactly what a real second account's entries would
/// answer — so the semantics under test are the production ones, only
/// the NE provider objects are synthetic.
final class IsolationWorkflow: TestWorkflow {
    override var displayName: String { "Isolation (Slot Classifier + Foreign Holder)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Classifier: Foreign Active Holds The Slot", foreignActiveHolds),
            WorkflowStep("Classifier: Own Undecodable Active Is Not Foreign", ownUndecodableIsOurs),
            WorkflowStep("Classifier: Idle Foreign Frees The Slot", idleForeignFrees),
            WorkflowStep("Gate: Engage Disarms Our Armed Rule, Release Follows", gateEngageAndRelease),
            WorkflowStep("Pre-flight: Foreign Holder Blocks Activation Cleanly", preflightBlocks),
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))

    private func foreignIdentity(name: String) -> TunnelIdentity {
        TunnelIdentity(id: UUID(), name: name, createdAt: Date(), isGhost: false)
    }

    /// The production funnel, verbatim: a side `TunnelsManager` over
    /// the canned providers, answering through the same
    /// `foreignSlotVerdict()` the activation belts call — loadAll →
    /// owner-scoped readAll → per-id probe → classifier, no step
    /// re-implemented. The manager's factory is canned, so nothing it
    /// does can touch real NE preferences.
    private func verdict(over providers: [TunnelProviding]) async -> SlotVerdict {
        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: FakeSlotFactory(canned: providers),
            vault: vault
        )
        return await manager.foreignSlotVerdict()
    }

    // MARK: - Steps

    private func foreignActiveHolds() async {
        guard case .configs = await vault.readAll() else {
            skip("environment: vault did not answer readAll")
            return
        }
        let foreign = FakeSlotProvider(
            name: "TE-Foreign-\(runTag)",
            identity: foreignIdentity(name: "TE-Foreign-\(runTag)"),
            status: .connected
        )
        let verdict = await verdict(over: [foreign])
        check(verdict == .heldByForeign(name: "TE-Foreign-\(runTag)"),
              "active session on a vault-unbacked id classifies as a foreign holder — verdict=\(verdict)")
    }

    private func ownUndecodableIsOurs() async {
        // A corrupt payload under OUR uid makes the id ours-but-broken:
        // the verdict must read the occupying session as our own
        // custody problem, never as a stranger to gate on.
        let corruptId = UUID()
        guard await vaultRaw.storeRaw(Data("corrupt".utf8), id: corruptId) else {
            fail("raw corrupt store refused")
            return
        }
        // Precondition, proven not assumed: the probe channel is alive
        // and answers .undecodable RIGHT NOW — without this, a vault
        // blip would make the check below pass vacuously (unverifiable
        // also classifies free) without touching the branch under test.
        guard case .undecodable = await vault.read(id: corruptId) else {
            fail("precondition broke — corrupt write did not read .undecodable")
            if !(await vault.delete(id: corruptId, attempts: 3)) {
                log("cleanup: corrupt plant delete failed — inert undecodable payload left in the vault", .warn)
            }
            return
        }
        let occupying = FakeSlotProvider(
            name: "TE-OwnBroken-\(runTag)",
            identity: TunnelIdentity(id: corruptId, name: "TE-OwnBroken-\(runTag)", createdAt: Date(), isGhost: false),
            status: .connected
        )
        let verdict = await verdict(over: [occupying])
        check(verdict == .free,
              "own undecodable payload's active session is NOT a foreign holder — verdict=\(verdict)")
        if !(await vault.delete(id: corruptId, attempts: 3)) {
            log("cleanup: corrupt plant delete failed — inert undecodable payload left in the vault", .warn)
        }
    }

    private func idleForeignFrees() async {
        guard case .configs = await vault.readAll() else {
            skip("environment: vault did not answer readAll")
            return
        }
        let foreign = FakeSlotProvider(
            name: "TE-ForeignIdle-\(runTag)",
            identity: foreignIdentity(name: "TE-ForeignIdle-\(runTag)"),
            status: .disconnected
        )
        let verdict = await verdict(over: [foreign])
        check(verdict == .free, "idle foreign entry does not hold the slot — verdict=\(verdict)")
    }

    private func gateEngageAndRelease() async {
        // This step keeps a REAL decodable payload in the vault for a
        // moment (the engage sweep only disarms providers the vault
        // owns). The LIVE manager's debounced reload must not sample
        // that window: its reconcile would mint a real NE entry for
        // the throwaway. Drain any pending debounce first — the step
        // itself fires no configuration changes, so the window that
        // follows is trigger-free.
        try? await Task.sleep(for: .milliseconds(600))
        guard let cfg = TestConfigFactory.throwaway(name: "TE-GateOwn-\(runTag)") else {
            fail("factory produced no config")
            return
        }
        guard await vault.store(cfg, attempts: 3) else {
            fail("store refused: \(cfg.name)")
            return
        }
        let own = FakeSlotProvider(
            name: cfg.name,
            identity: TunnelIdentity(id: cfg.id, name: cfg.name, createdAt: Date(), isGhost: false),
            status: .disconnected
        )
        own.isOnDemandEnabled = true // the armed rule that would feed the fight
        let foreign = FakeSlotProvider(
            name: "TE-GateForeign-\(runTag)",
            identity: foreignIdentity(name: "TE-GateForeign-\(runTag)"),
            status: .connected
        )
        let gate = ConnectionGateCoordinator(
            vault: vault,
            providerFactory: FakeSlotFactory(canned: [own, foreign])
        )

        await gate.evaluateNow()
        check(gate.state == .slotHeld(holderName: "TE-GateForeign-\(runTag)"),
              "gate engaged on the foreign holder — state=\(String(describing: gate.state))")
        check(!own.isOnDemandEnabled && own.saveCount >= 1,
              "engaging the gate disarmed our armed rule and persisted it (saves=\(own.saveCount))")

        foreign.connectionStatus = .disconnected
        await gate.evaluateNow()
        check(gate.state == .slotFree,
              "gate released once the foreign session went idle — state=\(String(describing: gate.state))")

        // Checked cleanup: a leftover decodable payload is NOT inert —
        // the live reconcile would materialize it as a real tunnel. If
        // this delete fails, that row will surface in the list; say so.
        if !(await vault.delete(id: cfg.id, attempts: 3)) {
            log("cleanup: vault delete failed — '\(cfg.name)' may appear in the tunnel list; delete it there", .warn)
        }
        // Belt for the drain race: a live reload that straddled the
        // 600ms drain can have reconciled the throwaway into a REAL
        // system entry mid-window. Remove it through the production
        // path (the vault delete above makes remove()'s own delete an
        // idempotent no-op, proven by Upsert Semantics) and prove the
        // list is clean either way.
        if let leaked = tunnel(named: cfg.name) {
            log("drain race minted a real entry for '\(cfg.name)' — removing it through the production path", .warn)
            try? await tunnels.remove(tunnel: leaked)
        }
        check(tunnel(named: cfg.name) == nil, "no residue row for '\(cfg.name)' in the live list")
    }

    private func preflightBlocks() async {
        // No vault write at all: the held verdict rests entirely on
        // the FOREIGN id probing `.missing` — whether our own row is
        // vault-backed is irrelevant to it. Skipping the store removes
        // the only residue this step could leave (a decodable payload
        // the live reconcile would materialize as a real tunnel).
        let ownName = "TE-PreflightOwn-\(runTag)"
        let own = FakeSlotProvider(
            name: ownName,
            identity: TunnelIdentity(id: UUID(), name: ownName, createdAt: Date(), isGhost: false),
            status: .disconnected
        )
        let foreign = FakeSlotProvider(
            name: "TE-PreForeign-\(runTag)",
            identity: foreignIdentity(name: "TE-PreForeign-\(runTag)"),
            status: .connected
        )
        // A side manager over synthetic providers and the real vault —
        // the production TunnelsManager type, isolated from the live
        // one the app runs (its factory is canned, so its reloads and
        // reconcile touch no real NE preferences).
        let manager = TunnelsManager(
            tunnelProviders: [own],
            providerFactory: FakeSlotFactory(canned: [own, foreign]),
            vault: vault
        )
        guard let container = manager.tunnels.first(where: { $0.id == own.tunnelIdentity?.id }) else {
            fail("side manager did not materialize the owned tunnel")
            return
        }

        manager.startActivation(of: container)
        // The pre-flight verdict is a readAll plus a per-id probe,
        // each behind its own 5s race timeout — budget past the
        // worst-case sum so a slow-but-answering vault cannot fake a
        // product FAIL.
        let start = Date()
        while Date().timeIntervalSince(start) < 12 {
            if container.lastActivationError != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        if case .foreignSlotHolder = container.lastActivationError {
            log("pre-flight named the foreign holder", .ok)
        } else {
            fail("expected .foreignSlotHolder, got \(String(describing: container.lastActivationError))")
        }
        check(container.status == .inactive, "tunnel returned to inactive — status=\(container.status)")
        check(!own.isEnabled, "isEnabled was never set against an occupied slot")
        check(!own.isOnDemandEnabled, "recovery was never armed against an occupied slot")
        check(own.saveCount == 0, "no preferences save was issued (saves=\(own.saveCount))")
        check(own.startCount == 0, "startTunnel was never called (starts=\(own.startCount))")
    }
}
#endif
