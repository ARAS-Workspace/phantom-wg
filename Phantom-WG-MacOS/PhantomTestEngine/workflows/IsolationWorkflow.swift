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
// Isolation (Slot Classifier + Foreign Holder)
//
// Cross-user isolation, stressed on a single identity. Synthetic foreign
// providers against the REAL vault: the classifier's foreign verdict rests
// on the daemon answering `.missing` for ids this user does not own —
// exactly what a real second account's entries would answer — so the
// semantics under test are the production ones and only the NE provider
// objects are synthetic. The gate-routing steps are the exception: they
// fabricate the vault as well, standing a `FaultVaultClient` up in place
// of the daemon so the manager's row and the gate's own reading can be
// made to disagree.
//
// The funnel is production verbatim: a side `TunnelsManager` over canned
// providers, answering through the same `foreignSlotVerdict()` the
// activation belts call — loadAll, owner-scoped `readAll`, per-id probe,
// classifier, with no step re-implemented. The manager's factory is
// canned, so nothing it does reaches real NE preferences.
//
// The synthetic provider is `FakeSlotProvider`, shared with the
// activation-seam steps, which need the same object to answer slowly or
// not at all.
//
// Scenarios, in three groups:
//
//   Classifier   A foreign ACTIVE session holds the slot; our own
//                UNDECODABLE payload is ours-but-broken rather than a
//                stranger to gate on; an idle foreign row frees the slot.
//
//   Gate         Engage disarms our armed rule and release follows; the
//                stand-down writes through the MANAGER's row when a
//                supplier is installed; a row being removed takes no
//                stand-down. The no-manager fallback and the routed path
//                are separate steps — neither covers the other.
//
//   Pre-flight   A proven foreign holder blocks activation cleanly, and a
//   and Seam     driven status reaches the real handler.
//
// Residue warning, and it is the heaviest in the suite: one plant is
// DECODABLE. Left behind, the next reconcile mints a real NE entry for it
// and the user inherits a tunnel they never imported. A step's own cleanup
// dies with a Stop; the teardown arm registered for it does not.

#if DEBUG
import Foundation
import NetworkExtension

final class IsolationWorkflow: TestWorkflow {
    override var displayName: String { "Isolation (Slot Classifier + Foreign Holder)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Classifier: Foreign Active Holds The Slot", foreignActiveHolds),
            WorkflowStep("Classifier: Own Undecodable Active Is Not Foreign", ownUndecodableIsOurs),
            WorkflowStep("Classifier: Idle Foreign Frees The Slot", idleForeignFrees),
            WorkflowStep("Gate: Engage Disarms Our Armed Rule, Release Follows", gateEngageAndRelease),
            WorkflowStep("Gate: The Stand-Down Writes Through The Manager's Row", gateRoutesThroughTheManager),
            WorkflowStep("Gate: A Row Being Removed Takes No Stand-Down", gateBarsARowBeingRemoved),
            WorkflowStep("Pre-flight: Foreign Holder Blocks Activation Cleanly", preflightBlocks),
            WorkflowStep("Seam: A Driven Status Reaches The Real Handler", drivenStatusReachesHandler),
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))

    private func foreignIdentity(name: String) -> TunnelIdentity {
        TunnelIdentity(id: UUID(), name: name, createdAt: Date(), isGhost: false)
    }

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
        let corruptId = UUID()
        guard await vaultRaw.storeRaw(Data("corrupt".utf8), id: corruptId) else {
            fail("raw corrupt store refused")
            return
        }
        onTeardown("corrupt plant") { [weak self] in
            guard let self else { return }
            switch await self.readPayloadState(corruptId) {
            case .missing:
                self.log("teardown: corrupt plant already swept by the step")
            case .unreachable:
                self.log("teardown: corrupt plant unverified — the vault did not answer, so whether it is still there "
                         + "was never observed", .error)
            case .present:
                switch await self.verifiedDelete(corruptId) {
                case .swept, .sweptOnReread:
                    self.log("teardown: corrupt plant swept", .warn)
                case .stillPresent:
                    self.log("teardown: corrupt plant is still in the vault after a verified sweep", .error)
                case .unverified:
                    self.log("teardown: corrupt plant sweep unverified — the vault went dark on the re-read", .error)
                }
            }
        }
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
        onTeardown("gate-own plant") { [weak self] in
            guard let self else { return }
            await self.sweepGateOwnPlant(cfg)
        }
        let own = FakeSlotProvider(
            name: cfg.name,
            identity: TunnelIdentity(id: cfg.id, name: cfg.name, createdAt: Date(), isGhost: false),
            status: .disconnected
        )
        own.arrangeArmed()
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

        foreign.setStatusSilently(.disconnected)
        await gate.evaluateNow()
        check(gate.state == .slotFree,
              "gate released once the foreign session went idle — state=\(String(describing: gate.state))")

        if case let outcome = await vault.delete(id: cfg.id, attempts: 3), outcome != .done {
            log("cleanup: vault delete \(outcome.label) — '\(cfg.name)' may appear in the tunnel list; delete it there", .warn)
        }
        if let leaked = tunnel(named: cfg.name) {
            log("drain race minted a real entry for '\(cfg.name)' — removing it through the production path", .warn)
            try? await tunnels.remove(tunnel: leaked)
        }
        check(tunnel(named: cfg.name) == nil, "no residue row for '\(cfg.name)' in the live list")
    }

    private func gateRoutesThroughTheManager() async {
        guard let held = TestConfigFactory.throwaway(name: "TE-GateRouted-\(runTag)"),
              let absent = TestConfigFactory.throwaway(name: "TE-GateAbsent-\(runTag)") else {
            fail("the config factory did not produce the two throwaways this step needs")
            return
        }
        let foreignName = "TE-GateRoutedForeign-\(runTag)"

        let managerHeld = armedProvider(for: held)
        let gateHeld = armedProvider(for: held)
        let gateAbsent = armedProvider(for: absent)
        let foreign = FakeSlotProvider(
            name: foreignName,
            identity: foreignIdentity(name: foreignName),
            status: .connected
        )

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([held, absent]))
        faultVault.readAnswer = .answers(.missing)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [managerHeld],
            providerFactory: FakeSlotFactory(canned: [managerHeld]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard manager.tunnels.contains(where: { $0.id == held.id }),
              !manager.tunnels.contains(where: { $0.id == absent.id }) else {
            fail("the rig did not come up as this claim needs — manager rows=\(manager.tunnels.map(\.id))")
            return
        }

        let gate = ConnectionGateCoordinator(
            vault: faultVault,
            providerFactory: FakeSlotFactory(canned: [gateHeld, gateAbsent, foreign])
        )
        gate.currentTunnelsManager = { manager }
        await gate.evaluateNow()

        guard check(gate.state == .slotHeld(holderName: foreignName),
                    "the gate engaged on the foreign holder, which is the only thing that runs the sweep — state=\(String(describing: gate.state))") else {
            return
        }
        check(managerHeld.saveCount == 1 && !managerHeld.storedOnDemand,
              "the stand-down landed on the MANAGER's provider and persisted there (saves=\(managerHeld.saveCount), store=\(managerHeld.storedOnDemand))")
        check(gateHeld.saveCount == 0 && gateHeld.isOnDemandEnabled,
              "and never on the gate's own copy of that same configuration, which is where it used to go (saves=\(gateHeld.saveCount), flag=\(gateHeld.isOnDemandEnabled))")
        check(gateAbsent.saveCount == 0 && gateAbsent.isOnDemandEnabled,
              "the row the manager's list does not hold was barred rather than written through the gate's object (saves=\(gateAbsent.saveCount), flag=\(gateAbsent.isOnDemandEnabled))")
    }

    private func gateBarsARowBeingRemoved() async {
        guard let removing = TestConfigFactory.throwaway(name: "TE-GateRemoving-\(runTag)"),
              let control = TestConfigFactory.throwaway(name: "TE-GateControl-\(runTag)") else {
            fail("the config factory did not produce the two throwaways this step needs")
            return
        }
        let foreignName = "TE-GateRemovingForeign-\(runTag)"

        let managerRemoving = armedProvider(for: removing)
        managerRemoving.removeAnswer = .succeedsAfter(seconds: 6)
        let managerControl = armedProvider(for: control)
        let gateRemoving = armedProvider(for: removing)
        let gateControl = armedProvider(for: control)
        let foreign = FakeSlotProvider(
            name: foreignName,
            identity: foreignIdentity(name: foreignName),
            status: .connected
        )

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([removing, control]))
        faultVault.readAnswers = [
            removing.id: .answers(.config(removing)),
            control.id: .answers(.config(control)),
        ]
        faultVault.readAnswer = .answers(.missing)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [managerRemoving, managerControl],
            providerFactory: FakeSlotFactory(canned: [managerRemoving, managerControl]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == removing.id }) else {
            fail("the side manager did not materialize the row this step removes")
            return
        }

        let removal = Task { @MainActor in (try? await manager.remove(tunnel: container)) != nil }
        guard await settle(within: 8, until: {
            manager.removingIds.contains(removing.id) && managerRemoving.removeCount == 1
        }) else {
            _ = await removal.value
            skip("environment: the removal never reached its held entry window")
            return
        }
        let savesBefore = managerRemoving.saveCount
        guard manager.tunnels.contains(where: { $0.id == removing.id }) else {
            _ = await removal.value
            skip("environment: the held removal window closed before the sweep could run")
            return
        }
        log("the row is still listed while its removal is in flight, so what refuses the save below is the removal bar")

        let gate = ConnectionGateCoordinator(
            vault: faultVault,
            providerFactory: FakeSlotFactory(canned: [gateRemoving, gateControl, foreign])
        )
        gate.currentTunnelsManager = { manager }
        await gate.evaluateNow()

        check(gate.state == .slotHeld(holderName: foreignName),
              "the gate engaged while a removal was in flight — state=\(String(describing: gate.state))")
        check(managerControl.saveCount == 1 && !managerControl.storedOnDemand,
              "the sweep ran and reached the loop: the row no removal owns came down (saves=\(managerControl.saveCount), store=\(managerControl.storedOnDemand))")
        check(managerRemoving.saveCount == savesBefore,
              "and the row being removed took no save at all, so nothing re-minted the entry the removal had already taken (saves=\(managerRemoving.saveCount), unchanged from \(savesBefore))")
        check(gateRemoving.saveCount == 0 && gateControl.saveCount == 0,
              "neither of the gate's own copies was written on either row (removing=\(gateRemoving.saveCount), control=\(gateControl.saveCount))")

        let removed = await removal.value
        guard removed else {
            fail("the removal itself failed, so the window this step measured was not the one production opens")
            return
        }
        check(!manager.tunnels.contains(where: { $0.id == removing.id })
              && !manager.removingIds.contains(removing.id),
              "the removal finished, its row left the list, and the bar came down with it —"
              + " a leaked bar makes that id un-startable and un-deletable for the life of the process")
    }

    private func armedProvider(for config: TunnelConfig) -> FakeSlotProvider {
        let provider = FakeSlotProvider(
            name: config.name,
            identity: TunnelIdentity(id: config.id, name: config.name, createdAt: Date(), isGhost: false),
            status: .disconnected
        )
        provider.arrangeArmed()
        return provider
    }

    private func preflightBlocks() async {
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
        let manager = TunnelsManager(
            tunnelProviders: [own],
            providerFactory: FakeSlotFactory(canned: [own, foreign]),
            vault: vault
        )
        guard let container = manager.tunnels.first(where: { $0.id == own.tunnelIdentity?.id }) else {
            fail("side manager did not materialize the owned tunnel")
            return
        }

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
        check(!own.isOnDemandEnabled && !own.storedOnDemand,
              "recovery was never armed against an occupied slot — in the flag or the store (flag=\(own.isOnDemandEnabled), store=\(own.storedOnDemand))")
        let disarmStart = Date()
        while Date().timeIntervalSince(disarmStart) < 3 {
            if own.saveCount >= 1 { break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        check(own.saveCount == 1,
              "the only preferences save was the collision stand-down (saves=\(own.saveCount), expected 1)")
        check(own.startCount == 0, "startTunnel was never called (starts=\(own.startCount))")
    }

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

        var reached = false
        let start = Date()
        while Date().timeIntervalSince(start) < 3 {
            if container.status == .active { reached = true; break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        check(reached, "driven .connected reached the real handler — status=\(container.status)")

        let driven = Notification(name: .NEVPNStatusDidChange, object: fake, userInfo: nil)
        let claimedByReal = tunnels.tunnels.filter { $0.tunnelProvider.matchesNotification(driven) }
        check(claimedByReal.isEmpty,
              "no real tunnel matches a driven notification (\(claimedByReal.count) of \(tunnels.tunnels.count) claimed it)")

        check(!fake.matchesNotification(Notification(name: .NEVPNStatusDidChange, object: NSObject(), userInfo: nil)),
              "a foreign object's notification does not match this provider")
    }

    private func sweepGateOwnPlant(_ cfg: TunnelConfig) async {
        var notes: [String] = []
        var stuck = false
        if let materialized = tunnel(named: cfg.name) {
            do {
                try await tunnels.remove(tunnel: materialized)
                notes.append("materialized row removed")
            } catch {
                notes.append("materialized row still listed (\(error.localizedDescription))")
                stuck = true
            }
        }
        var payloadGone = false
        switch await readPayloadState(cfg.id) {
        case .missing:
            payloadGone = true
        case .unreachable:
            notes.append("vault unreachable — payload state unverified")
            stuck = true
        case .present:
            switch await verifiedDelete(cfg.id) {
            case .swept, .sweptOnReread:
                notes.append("payload swept")
                payloadGone = true
            case .stillPresent:
                notes.append("payload still in the vault after a verified sweep")
                stuck = true
            case .unverified:
                notes.append("payload sweep unverified — the vault went dark on the re-read")
                stuck = true
            }
        }
        if payloadGone {
            let (entryNotes, entryStuck) = await probeHiddenSurvivor(id: cfg.id)
            notes.append(contentsOf: entryNotes)
            stuck = stuck || entryStuck
        } else {
            notes.append("entry left in place — its payload was not observed gone")
        }
        log("teardown: gate-own plant — \(notes.isEmpty ? "already swept by the step" : notes.joined(separator: ", "))",
                 stuck ? .error : (notes.isEmpty ? .info : .warn))
    }
}
#endif
