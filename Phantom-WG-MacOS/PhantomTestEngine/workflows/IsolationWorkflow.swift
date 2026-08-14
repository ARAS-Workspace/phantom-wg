#if DEBUG
import Foundation
import NetworkExtension

// The synthetic provider these steps drive lives in
// PhantomTestEngine/FakeSlotProvider.swift — shared with the
// activation-seam steps, which need the same object to answer slowly
// or not at all.

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
            WorkflowStep("Seam: A Driven Status Reaches The Real Handler", drivenStatusReachesHandler),
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
        // The step sweeps this on every path it reaches, but under a
        // Stop it cannot: a cancelled task's `vault.delete` answers
        // `.unreachable` without sending anything. This is the only
        // sweep that still works on that path.
        onTeardown("corrupt plant") { [weak self] in
            guard let self else { return }
            if case .missing = await self.vault.read(id: corruptId) {
                self.log("teardown: corrupt plant already swept by the step")
                return
            }
            let outcome = await self.vault.delete(id: corruptId, attempts: 3)
            self.log("teardown: corrupt plant delete \(outcome.label)", outcome == .done ? .warn : .error)
        }
        // Precondition, proven not assumed: the probe channel is alive
        // and answers .undecodable RIGHT NOW — without this, a vault
        // blip would make the check below pass vacuously (unverifiable
        // also classifies free) without touching the branch under test.
        guard case .undecodable = await vault.read(id: corruptId) else {
            fail("precondition broke — corrupt write did not read .undecodable")
            if case let outcome = await vault.delete(id: corruptId, attempts: 3), outcome != .done {
                log("cleanup: corrupt plant delete \(outcome.label) — an inert undecodable payload may remain in the vault", .warn)
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
        if case let outcome = await vault.delete(id: corruptId, attempts: 3), outcome != .done {
            log("cleanup: corrupt plant delete \(outcome.label) — an inert undecodable payload may remain in the vault", .warn)
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
        let stored = await vault.store(cfg, attempts: 3)
        guard stored == .done else {
            fail("store \(stored.label): \(cfg.name)")
            return
        }
        // This one is DECODABLE, which makes it the heaviest residue
        // in the suite: left behind, the next reconcile mints a real
        // NE entry for it and the user inherits a tunnel they never
        // imported. The step's own cleanup dies with a Stop; this does
        // not.
        onTeardown("gate-own plant") { [weak self] in
            guard let self else { return }
            var notes: [String] = []
            var stuck = false
            // Row first, payload second, and the order is the whole
            // point: deleting the payload while a materialized row is
            // still listed makes the next ingest read `.missing` for
            // it, file it under another user and hide it — leaving a
            // system entry nothing in this app can reach again.
            // `remove()` takes the payload down with the row anyway.
            if let materialized = self.tunnel(named: cfg.name) {
                do {
                    try await self.tunnels.remove(tunnel: materialized)
                    notes.append("materialized row removed")
                } catch {
                    notes.append("materialized row still listed (\(error.localizedDescription))")
                    stuck = true
                }
            }
            switch await self.vault.read(id: cfg.id) {
            case .missing:
                break // Gone, by the step or by the remove above.
            case .unreachable:
                // A reading that verified nothing claims nothing —
                // and loudly, per the cleanup doctrine.
                notes.append("vault unreachable — payload state unverified")
                stuck = true
            default:
                switch await self.vault.delete(id: cfg.id, attempts: 3) {
                case .done:
                    notes.append("payload swept")
                case .refused:
                    notes.append("payload delete refused")
                    stuck = true
                case .unreachable:
                    notes.append("vault went unreachable — payload state unverified")
                    stuck = true
                }
            }
            self.log("teardown: gate-own plant — \(notes.isEmpty ? "already swept by the step" : notes.joined(separator: ", "))",
                     stuck ? .error : (notes.isEmpty ? .info : .warn))
        }
        let own = FakeSlotProvider(
            name: cfg.name,
            identity: TunnelIdentity(id: cfg.id, name: cfg.name, createdAt: Date(), isGhost: false),
            status: .disconnected
        )
        own.arrangeArmed() // the armed rule that would feed the fight
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
        check(!own.isOnDemandEnabled && !own.storedOnDemand && own.saveCount >= 1,
              "engaging the gate disarmed our armed rule and PERSISTED it — the save count alone would also count a refusal (flag=\(own.isOnDemandEnabled), store=\(own.storedOnDemand), saves=\(own.saveCount))")

        // Silently: this step drives the gate by hand below, and a
        // published notification would hand the same transition to the
        // manager's observer as well.
        foreign.setStatusSilently(.disconnected)
        await gate.evaluateNow()
        check(gate.state == .slotFree,
              "gate released once the foreign session went idle — state=\(String(describing: gate.state))")

        // Checked cleanup: a leftover decodable payload is NOT inert —
        // the live reconcile would materialize it as a real tunnel. If
        // this delete fails, that row will surface in the list; say so.
        if case let outcome = await vault.delete(id: cfg.id, attempts: 3), outcome != .done {
            log("cleanup: vault delete \(outcome.label) — '\(cfg.name)' may appear in the tunnel list; delete it there", .warn)
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

        // The rung-0 pre-flight rides a 2s verdict deadline and costs
        // at least TWO sequential vault round-trips (readAll + the
        // per-id probe), so the gate must fit two RTTs plus slack
        // inside 2s — one ping under 0.8s is the proxy. A vault
        // slower than that legitimately reads .free (unverifiable)
        // and the activation proceeds: product behavior, not a
        // product bug. Non-ready answers are their own stories, not
        // slowness.
        let pingStart = Date()
        let pingAnswer = await vault.ping()
        let pingRTT = Date().timeIntervalSince(pingStart)
        switch pingAnswer {
        case .doorFailed(let identity):
            fail("vault door failed — identity=\(identity)")
            return
        case .unreachable:
            skip("environment: vault unreachable")
            return
        case .ready:
            guard pingRTT < 0.8 else {
                skip("environment: vault RTT \(String(format: "%.2f", pingRTT))s — two verdict round-trips cannot fit the 2s pre-flight deadline")
                return
            }
        }

        manager.startActivation(of: container)
        // Poll budget covers the 2s verdict deadline plus scheduling
        // slack; the belts settle the error well inside it.
        let start = Date()
        while Date().timeIntervalSince(start) < 12 {
            if container.lastActivationError != nil { break }
            if Task.isCancelled { break }
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

    /// The seam itself, proven before anything is built on it.
    ///
    /// The activation belts hang off `handleStatusChange`, and the only
    /// door into that method is an `.NEVPNStatusDidChange` the manager
    /// matches to one of its tunnels. Until now the harness had no way
    /// to knock on it: real sessions decide their own timing, and the
    /// synthetic provider answered `matchesNotification` with a flat
    /// `false`. This step proves the driven notification arrives, is
    /// matched to the right tunnel, and runs the production handler —
    /// and, just as importantly, that a fake's notification is invisible
    /// to the app's real tunnels.
    private func drivenStatusReachesHandler() async {
        let identity = foreignIdentity(name: "TE-Seam-\(runTag)")
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the seam tunnel")
            return
        }
        guard container.status == .inactive else {
            fail("seam tunnel did not start from inactive — status=\(container.status)")
            return
        }

        fake.drive(.connected)

        // The observer hops through a Task on the main queue, so the
        // handler runs after this call returns rather than inside it.
        var reached = false
        let start = Date()
        while Date().timeIntervalSince(start) < 3 {
            if container.status == .active { reached = true; break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        check(reached, "driven .connected reached the real handler — status=\(container.status)")

        // The other half of the isolation claim, asked directly rather
        // than inferred: no real tunnel answers to this notification.
        // Comparing the live tunnels' statuses before and after would
        // have been the same sentence with a timing bug in it — a real
        // session transitioning on its own during the wait would fail
        // a claim that was never about it.
        let driven = Notification(name: .NEVPNStatusDidChange, object: fake, userInfo: nil)
        let claimedByReal = tunnels.tunnels.filter { $0.tunnelProvider.matchesNotification(driven) }
        check(claimedByReal.isEmpty,
              "no real tunnel matches a driven notification (\(claimedByReal.count) of \(tunnels.tunnels.count) claimed it)")

        // And the deliberate negative: a notification carrying someone
        // else's object must not match this provider.
        check(!fake.matchesNotification(Notification(name: .NEVPNStatusDidChange, object: NSObject(), userInfo: nil)),
              "a foreign object's notification does not match this provider")
    }
}
#endif
