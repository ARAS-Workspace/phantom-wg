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
// objects are synthetic. The gate-routing steps are the exception and
// fabricate the vault as well; each says so in its own place.
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
            // Three-valued at both ends. The read told `.missing` apart
            // from the rest already; what it did not do was tell a
            // SILENT vault apart from a present payload — both fell
            // into the delete below, whose answer was then read as a
            // Bool. A delete that goes dark has still possibly landed,
            // and reporting that as a failed sweep sends a reader
            // looking for bytes that are not there.
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
            await self.sweepGateOwnPlant(cfg)
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
        // No supplier is installed here, and that is now what this step
        // measures: the gate's NO-MANAGER fallback, which writes through
        // its own copy without the removal bars. The routed path — the
        // one production takes once a list exists — is the two steps
        // below. Neither covers the other.
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

    /// Where the gate's stand-down actually lands.
    ///
    /// The gate loads its OWN providers, so its objects are never the
    /// ones this app's containers wrap: the same configurations, two
    /// system reads apart. That is why it cannot reach the liveness bars
    /// by itself — they are read off a container and object identity
    /// will never match across two reads — and why a save issued on its
    /// own copy would repair nothing the manager can see.
    ///
    /// Two rows are given to the gate and only one of them is in the
    /// manager's list, so the pass proves both halves at once: the write
    /// goes through the manager's provider for the row it holds, and the
    /// row it does not hold is barred rather than written through the
    /// gate's object. Each half is the other's control — a bar that
    /// silently swallowed the whole sweep would take the first check
    /// down with it.
    ///
    /// Every surface is fabricated, the vault included. The ownership
    /// answer is what decides which rows the sweep considers at all, and
    /// buying it with real payloads would put throwaways in the user's
    /// own vault for a claim that is not about the vault. Nothing here
    /// touches NE preferences, the real vault, or a real provider, so
    /// there is no residue and no teardown net.
    private func gateRoutesThroughTheManager() async {
        guard let held = TestConfigFactory.throwaway(name: "TE-GateRouted-\(runTag)"),
              let absent = TestConfigFactory.throwaway(name: "TE-GateAbsent-\(runTag)") else {
            fail("the config factory did not produce the two throwaways this step needs")
            return
        }
        let foreignName = "TE-GateRoutedForeign-\(runTag)"

        // The manager's side of the same configuration.
        let managerHeld = armedProvider(for: held)
        // The gate's side: different objects, same identities.
        let gateHeld = armedProvider(for: held)
        let gateAbsent = armedProvider(for: absent)
        let foreign = FakeSlotProvider(
            name: foreignName,
            identity: foreignIdentity(name: foreignName),
            status: .connected
        )

        let faultVault = FaultVaultClient()
        // Both rows read as ours, which is what puts them in front of
        // the sweep in the first place.
        faultVault.readAllAnswer = .answers(.configs([held, absent]))
        // The only per-id probe on this path is the classifier's, for
        // the id outside the owned set — and absence IS the foreign
        // verdict. Fabricated rather than left real so a call this step
        // did not anticipate cannot reach the user's own vault.
        faultVault.readAnswer = .answers(.missing)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [managerHeld],
            providerFactory: FakeSlotFactory(canned: [managerHeld]),
            vault: faultVault,
            observesSystemChanges: false
        )
        // The arrangement is measured, not assumed: the whole claim
        // rests on the manager holding exactly one of the two rows.
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

    /// The bar the routing exists to buy.
    ///
    /// This site runs while another user's session holds the slot, which
    /// is exactly when somebody is likely to be deleting the tunnel that
    /// will not connect. A stand-down landing on an entry a removal has
    /// just taken puts that entry back — armed, behind a list that no
    /// longer holds it — which is the hidden-entry class this campaign
    /// exists to close.
    ///
    /// A second row carries the control, and it is what makes the
    /// negative mean anything: it is owned, armed and untouched by any
    /// removal, so it must come down in the same pass. Without it, "no
    /// save on the removing row" would read the same whether the bar
    /// held or the sweep never reached the loop.
    private func gateBarsARowBeingRemoved() async {
        guard let removing = TestConfigFactory.throwaway(name: "TE-GateRemoving-\(runTag)"),
              let control = TestConfigFactory.throwaway(name: "TE-GateControl-\(runTag)") else {
            fail("the config factory did not produce the two throwaways this step needs")
            return
        }
        let foreignName = "TE-GateRemovingForeign-\(runTag)"

        let managerRemoving = armedProvider(for: removing)
        // The removal is held open at the system entry, which is where
        // the window this step needs actually is.
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
        // Decodable, so the removal takes the entry FIRST — which is the
        // order that opens the window at all: the entry is what a late
        // save re-mints.
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
        // Waited out to the HELD entry removal rather than to the bar
        // alone: the removal lowers the rule before it touches the
        // entry, so a snapshot taken at the bar would be racing that
        // save instead of measuring past it.
        guard await settle(within: 8, until: {
            manager.removingIds.contains(removing.id) && managerRemoving.removeCount == 1
        }) else {
            _ = await removal.value
            skip("environment: the removal never reached its held entry window")
            return
        }
        let savesBefore = managerRemoving.saveCount
        // WHICH bar answers is the claim. `standDownForSlotGate` also
        // bars an id the list does not hold, and a row that had already
        // left the list would take this step green for the wrong
        // reason. It has not left while the entry removal is held — and
        // if the hold has run out on a slow machine the arrangement is
        // simply gone, which is an environment exit and not a broken
        // contract: nothing was measured either way.
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

        // The counters below are read with no await between them and
        // the sweep, and that is load-bearing rather than tidy: an
        // engaged gate polls every three seconds, and in THIS rig its
        // canned providers never see the manager's save, so each poll
        // finds them armed and sweeps again. Production does not repeat
        // that way — its gate re-reads the system list, where the
        // manager's write is visible — so the repetition is a property
        // of the rig, and termination itself is not something this rig
        // can witness.
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

    /// A provider standing for a config the system already holds, armed
    /// the way one loaded from the system comes in.
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
        check(!own.isOnDemandEnabled && !own.storedOnDemand,
              "recovery was never armed against an occupied slot — in the flag or the store (flag=\(own.isOnDemandEnabled), store=\(own.storedOnDemand))")
        // The contract as of this session, and the reason the number
        // moved: the collision exit used to leave this slot alone, which
        // read as "nothing was written" and was in fact "the one exit
        // that proved a foreign holder and left our rule wherever it
        // was". It now stands the rule down like every sibling belt, so
        // exactly ONE save belongs to this path — and it is a
        // stand-down, never an arm, which the flag and store above say
        // in their own right. (The previous version asserted zero and
        // went red on that change: the guard doing its job.)
        // Waited for, then pinned: the stand-down is issued AFTER the
        // verdict is written and on the far side of an executor hop, so
        // reading the counter the instant the error appears would race
        // it. The window closes on the first save; the equality then
        // says no second one followed.
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

    /// The gate-own plant's sweep, lifted out of its net when the
    /// entry-probe gating pushed the closure past the length ruler.
    /// The net stays the registration; this is what it does.
    private func sweepGateOwnPlant(_ cfg: TunnelConfig) async {
        var notes: [String] = []
        var stuck = false
        // Row first, payload second, and the order is the whole
        // point: deleting the payload while a materialized row is
        // still listed makes the next ingest read `.missing` for
        // it, file it under another user and hide it — leaving a
        // system entry nothing in this app can reach again.
        // `remove()` takes the payload down with the row anyway.
        if let materialized = tunnel(named: cfg.name) {
            do {
                try await tunnels.remove(tunnel: materialized)
                notes.append("materialized row removed")
            } catch {
                notes.append("materialized row still listed (\(error.localizedDescription))")
                stuck = true
            }
        }
        // Through the kit at both ends. The `.unreachable` arm
        // was already honest — that is not what changed. What did:
        // the DELETE's answer was read as three values but never
        // re-read, so a delete whose reply was lost counted as a
        // refusal; and the entry side asked only the mirror above,
        // which cannot see a payload-less entry at all, since the
        // ownership boundary files one as another local user's and
        // drops it from the list.
        var payloadGone = false
        switch await readPayloadState(cfg.id) {
        case .missing:
            payloadGone = true // Gone, by the step or by the remove above.
        case .unreachable:
            // A reading that verified nothing claims nothing —
            // and loudly, per the cleanup doctrine.
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
        // Gated on the payload being PROVABLY gone. The probe does
        // not merely look — it removes a surviving entry — so over a
        // payload that is still there, or whose state the vault never
        // answered for, it would take away the bytes' only anchor.
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
