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
// Activation Seam — The Disarm-Save Ledger
//
// Steps belonging to `ActivationSeamWorkflow`; the registry lives in the
// main file. Their subject is the manager's own memory of the disarm
// saves it has opened and not yet seen land: a second disarm JOINS the
// save in flight rather than stacking another against a store that is not
// answering, a row retires the moment its save lands so the next disarm
// opens its own, and a removal WAITS a lingering save out before touching
// the system entry — the order between a late save and removePreferences
// is not this app's to control once the removal moves on. An edit takes
// the removal's wait, in the removal's order: `modify` awaits the ledger
// before it writes either store. The rung's arm save orders itself the
// same way, to the user's patience rather than the store ceiling, and the
// uninstall sweep waits on the LISTED row's provider — the object the
// ledger keys by — before taking its entry.

#if DEBUG
import Foundation

extension ActivationSeamWorkflow {

    func aSecondDisarmJoinsTheSaveInFlight() async {
        guard let rig = sideRow("TE-Seam-JoinedSave-\(runTag)", status: .connected, configure: {
            $0.isEnabled = true
            $0.arrangeArmed()
            $0.saveAnswer = .hangs
        }) else { return }
        let (fake, container, manager) = rig
        onTeardown("wedged stop-disarm (joined-save rig)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the joined-save rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the joined-save rig")
        }

        manager.startDeactivation(of: container)
        guard await settle(within: 5, until: { fake.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fake.saveCount))")
            return
        }
        manager.startDeactivation(of: container)
        check(fake.stopCount == 1,
              "the second press put its stop out inline — the flag already carries the first press's write (stops=\(fake.stopCount))")
        let lingering = await TunnelsManager.awaitLingeringDisarmSave(on: fake, within: 0.5)
        check(!lingering,
              "the ledger's bounded wait answers false while the save is in flight, rather than pretending it landed")

        guard await settle(within: 8, until: { container.pendingDisarmCount == 0 }) else {
            fail("the first press never reached its terminal answer — count=\(container.pendingDisarmCount)")
            return
        }
        let chainDone: Void? = await race(10) { await container.pendingDisarmTask?.value }
        guard check(chainDone != nil, "every deferred stop flow reached its own terminal answer") else { return }
        check(fake.saveCount == 1,
              "one save serves both presses: the repair JOINED the save in flight instead of stacking a second one (saves=\(fake.saveCount))")
        var namedSilence = false
        if case .stopRuleStandDownUnconfirmed = container.lastActivationError { namedSilence = true }
        check(namedSilence,
              "each waiter ended at its own patience naming the silence — error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(fake.stopCount == 2,
              "and each press carried its own stop — joining the save stacks no stops and skips none (stops=\(fake.stopCount))")
        check(!fake.isOnDemandEnabled && fake.storedOnDemand,
              "while nothing landed in the store: the joined save is the only writer and it has not answered (flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand))")

        fake.saveAnswer = .succeeds
        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
        let retired = await TunnelsManager.awaitLingeringDisarmSave(on: fake, within: 5)
        check(retired, "the ledger row retired the moment its save landed")

        fake.drive(.connected)
        guard await settle(within: 3, until: { container.status == .active }) else {
            fail("the risen session never repainted the row — status=\(container.status)")
            return
        }
        fake.arrangeArmed()
        var sentenceStands = false
        if case .stopRuleStandDownUnconfirmed = container.lastActivationError { sentenceStands = true }
        guard check(sentenceStands,
                    "the unconfirmed sentence still stands over the risen row — the rise keeps it on"
                    + " purpose, so the .done below has something to refute") else { return }
        manager.startDeactivation(of: container)
        let reopened = await settle(within: 5) { fake.saveCount >= 2 }
        check(reopened,
              "and the NEXT disarm opened its own save rather than joining the retired row (saves=\(fake.saveCount))")
        guard await settle(within: 8, until: { container.pendingDisarmCount == 0 }) else {
            fail("the second armed stop never reached its terminal answer — count=\(container.pendingDisarmCount)")
            return
        }
        check(container.lastActivationError == nil,
              "and its save landing .done refuted the sentence: a stand-down that provably landed closes"
              + " the question the unconfirmed sentence asked — error="
              + "\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
    }

    func removalWaitsOutALingeringDisarmSave() async {
        guard let rig = sideRow("TE-Seam-RemoveWaits-\(runTag)", status: .connected, configure: {
            $0.isEnabled = true
            $0.arrangeArmed()
            $0.saveAnswer = .hangs
        }) else { return }
        let (fake, container, manager) = rig
        onTeardown("wedged stop-disarm (remove-waits rig)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the remove-waits rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the remove-waits rig")
        }

        manager.startDeactivation(of: container)
        guard await settle(within: 5, until: { fake.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fake.saveCount))")
            return
        }
        let tunnelId = container.id
        let removal = Task { @MainActor in (try? await manager.remove(tunnel: container)) != nil }
        guard await settle(within: 5, until: { manager.removingIds.contains(tunnelId) }) else {
            _ = await removal.value
            skip("environment: the removal never reached its in-flight window (vault slow?)")
            return
        }
        guard await settle(within: 8, until: { container.pendingDisarmCount == 0 }) else {
            fail("the parked stop never reached its terminal answer — count=\(container.pendingDisarmCount)")
            _ = await removal.value
            return
        }
        check(fake.removeCount == 0,
              "the removal has not touched the system entry while the stop's disarm save is still in flight — the ledger wait holds it (removes=\(fake.removeCount))")
        check(fake.saveCount == 1,
              "and opened no save race of its own against that wedge — it joined the save it found (saves=\(fake.saveCount))")

        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
        guard let removed = await race(30, { await removal.value }), removed else {
            skip("environment: the removal itself failed (vault dark?) — the ordering contract is unproven this run")
            return
        }
        check(fake.removeCount == 1,
              "the entry went exactly once, and only AFTER the lingering save had landed — the two reads around the release are the order (removes=\(fake.removeCount))")
        check(!manager.tunnels.contains(where: { $0.id == tunnelId }), "the tunnel left the list")
        check(fake.saveCount == 1,
              "one save total: the wedged disarm was joined by the stop's park and the removal's own stand-down alike (saves=\(fake.saveCount))")
    }

    // D3: remove()'s symmetry, in remove()'s order — a disarm save still
    // on the ledger is waited out before the edit writes the vault or the
    // system store. The two reads around the release are the order. The
    // vault here is a driven one that answers about nothing, so the only
    // writes it can record are this edit's own.
    func anEditWaitsOutALingeringDisarmSave() async {
        guard let config = TestConfigFactory.throwaway(name: "TE-Seam-EditWaits-\(runTag)") else {
            fail("the config factory did not produce the throwaway this step needs")
            return
        }
        let fake = FakeSlotProvider(name: config.name, identity: config.identity, status: .connected)
        fake.isEnabled = true
        fake.arrangeArmed()
        fake.saveAnswer = .hangs
        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([]))
        faultVault.storeAnswer = .answers(.done)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == config.id }) else {
            fail("side manager did not materialize the edit-waits tunnel")
            return
        }
        onTeardown("wedged stop-disarm (edit-waits rig)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the edit-waits rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the edit-waits rig")
        }

        manager.startDeactivation(of: container)
        guard await settle(within: 5, until: { fake.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fake.saveCount))")
            return
        }

        var renamed = config
        renamed.name = "TE-Seam-EditWaitsNew-\(runTag)"
        let editName = renamed.name
        let edit = Task { @MainActor in
            (try? await manager.modify(tunnel: container, with: renamed)) != nil
        }
        let editWroteEarly = await settle(within: 2) {
            fake.saveCount > 1 || !faultVault.storedIds.isEmpty
        }
        check(!editWroteEarly && fake.saveCount == 1 && faultVault.storedIds.isEmpty,
              "the edit has written NOTHING while the disarm save is in flight — no vault store, no"
              + " preferences save: the ledger wait holds it"
              + " (saves=\(fake.saveCount), stores=\(faultVault.storedIds.count))")

        fake.saveAnswer = .succeeds
        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
        guard let edited = await race(20, { await edit.value }), edited else {
            fail("the edit never completed once the lingering save had landed")
            return
        }
        check(fake.saveCount == 2,
              "the edit's own save went out only AFTER the lingering disarm save landed — the two reads"
              + " around the release are the order (saves=\(fake.saveCount))")
        check(faultVault.storedIds == [config.id],
              "and exactly one vault write followed, the edit's own"
              + " (stores=\(faultVault.storedIds.count))")
        check(container.name == editName,
              "the edit landed whole — name=\(container.name)")

        _ = await settle(within: 8) { container.pendingDisarmCount == 0 }
        fake.drive(.disconnected)
        _ = await settle(within: 3) { container.status == .inactive }
    }

    /// The rig the two rung-order steps share: an armed, connected row on
    /// a driven vault, so the rung-0 slot verdict is an arrangement and
    /// the ledger window below is the only clock in the step.
    private func armedLedgerRig(_ label: String) -> (
        fake: FakeSlotProvider, container: TunnelContainer, manager: TunnelsManager
    )? {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-\(label)-\(runTag)",
                                      createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .connected)
        fake.isEnabled = true
        fake.arrangeArmed()
        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([]))
        faultVault.readAnswer = .answers(.missing)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the \(label) tunnel")
            return nil
        }
        return (fake, container, manager)
    }

    // The race the rung's own wait closes: a stop's disarm save that lands
    // LATE must not land behind the next press's arm save — two saves in
    // flight land in an order the system owns. The step is red against a
    // rung that arms without asking the ledger: its arm save would go out
    // while the ledger row is provably still open, which the in-flight
    // reading below catches. The disarm is HELD, the family's
    // held-completion pattern, and released only once the rung is proven
    // parked — so no wall clock races the step's own arrangement.
    func armSaveDoesNotRaceALingeringDisarmSave() async {
        guard let rig = armedLedgerRig("ArmRace") else { return }
        let (fake, container, manager) = rig
        fake.saveAnswer = .hangs
        onTeardown("wedged disarm (arm-race rig)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the arm-race rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the arm-race rig")
        }

        manager.startDeactivation(of: container)
        guard await settle(within: 5, until: { fake.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fake.saveCount))")
            return
        }
        guard await settle(within: 6, until: { container.pendingDisarmCount == 0 }) else {
            fail("the parked stop never ended at its patience — count=\(container.pendingDisarmCount)")
            return
        }
        var namedSilence = false
        if case .stopRuleStandDownUnconfirmed = container.lastActivationError { namedSilence = true }
        check(namedSilence,
              "the stop ended at the user's patience with the save still in flight, naming the silence —"
              + " error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        fake.drive(.disconnected)
        guard await settle(within: 3, until: { container.status == .inactive }) else {
            fail("the driven drop never grounded the row — status=\(container.status)")
            return
        }

        // KONTROL ONDE: the ledger row is provably still open when the
        // press below lands — the bar must not green its own claim.
        let lingering = await TunnelsManager.awaitLingeringDisarmSave(on: fake, within: 0.5)
        guard check(!lingering,
                    "the disarm save is still OPEN on the ledger as the press lands — the race window this"
                    + " step is about is real") else { return }

        // The held completion is already issued, so restoring the answer
        // cannot reach it: the arm save below answers at once while the
        // ledger row alone stays open.
        fake.saveAnswer = .succeeds
        manager.startActivation(of: container)
        // Every other answer in this rig is instant, so a press whose arm
        // save has not gone out after this settle is parked on the one
        // wait between the entry and the arm — the ledger row.
        let pressedEarly = await settle(within: 1) { fake.saveCount >= 2 }
        guard check(!pressedEarly && fake.saveCount == 1,
                    "the press is parked inside the rung's ledger wait — its arm save has not gone out"
                    + " while the disarm save is still in flight (saves=\(fake.saveCount))") else { return }

        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
        let retired = await TunnelsManager.awaitLingeringDisarmSave(on: fake, within: 5)
        check(retired,
              "the released landing retired the ledger row — the rung's wait has its answer")
        let armed = await settle(within: 5) { fake.saveCount >= 2 }
        check(armed && fake.saveCount == 2,
              "and the press's arm save went out only past that landing — the two reads around the"
              + " release are the order (saves=\(fake.saveCount))")
        guard await settle(within: 8, until: { fake.startCount >= 1 }) else {
            skip("environment: the press never reached startTunnel")
            return
        }
        fake.drive(.connected)
        guard await settle(within: 3, until: { container.status == .active }) else {
            fail("the driven session never reached the handler — status=\(container.status)")
            return
        }
        check(fake.storedOnDemand,
              "with the store ending ARMED on the press's own write — nothing landed behind it"
              + " (store=\(fake.storedOnDemand))")
    }

    // The wait's other exit: the ledger row nobody will ever answer costs
    // the press the user-patience bound and NOTHING more — the rung then
    // arms with the save in flight, by the same decision modify and remove
    // take at their ceilings.
    func aLedgerSaveNobodyAnswersCannotParkThePress() async {
        guard let rig = armedLedgerRig("ArmCeiling") else { return }
        let (fake, container, manager) = rig
        fake.saveAnswer = .hangs
        onTeardown("wedged disarm (arm-ceiling rig)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the arm-ceiling rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the arm-ceiling rig")
        }

        manager.startDeactivation(of: container)
        guard await settle(within: 5, until: { fake.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fake.saveCount))")
            return
        }
        guard await settle(within: 6, until: { container.pendingDisarmCount == 0 }) else {
            fail("the parked stop never ended at its patience — count=\(container.pendingDisarmCount)")
            return
        }
        fake.drive(.disconnected)
        guard await settle(within: 3, until: { container.status == .inactive }) else {
            fail("the driven drop never grounded the row — status=\(container.status)")
            return
        }
        // The held completion is already issued, so later saves — the arm
        // below — answer at once while the ledger row stays open.
        fake.saveAnswer = .succeeds
        let lingering = await TunnelsManager.awaitLingeringDisarmSave(on: fake, within: 0.5)
        guard check(!lingering,
                    "the wedged disarm save is provably still open on the ledger as the press lands")
        else { return }

        let pressed = Date()
        manager.startActivation(of: container)
        guard await settle(within: 10, until: { fake.saveCount >= 2 }) else {
            fail("the press never reached its arm save past the ledger wait (saves=\(fake.saveCount))")
            return
        }
        let waited = Date().timeIntervalSince(pressed)
        check(waited >= TunnelsManager.disarmPatience - 0.3,
              "the arm save came out only at the wait's own ceiling — the rung really waited on a save"
              + " nobody answers (waited \(String(format: "%.1f", waited))s)")
        check(fake.storedOnDemand,
              "and it armed with the save still in flight — the ceiling bounds the WAIT, it is not a"
              + " verdict on the press (store=\(fake.storedOnDemand))")
        let started = await settle(within: 5) { fake.startCount >= 1 }
        check(started, "with the start going out behind it (starts=\(fake.startCount))")
        let stillOpen = await TunnelsManager.awaitLingeringDisarmSave(on: fake, within: 0.3)
        check(!stillOpen,
              "while the ledger row is STILL open — nothing pretended the save landed")

        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
    }

    // remove()'s wait, run by the uninstall sweep — and on the LISTED
    // row's provider, because the ledger keys by provider object and the
    // freshly loaded copy the sweep iterates does not carry the listed
    // row's lingering save. The twin drives the other doorway: a row the
    // list does not hold has no ledger entry to wait on, and its removal
    // still goes out.
    func uninstallSweepWaitsOutALingeringDisarmSave() async {
        guard let rig = sideRow("TE-Seam-SweepLedger-\(runTag)", status: .connected, configure: {
            $0.isEnabled = true
            $0.arrangeArmed()
            $0.saveAnswer = .hangs
        }) else { return }
        let (fake, container, manager) = rig
        onTeardown("wedged stop-disarm (sweep-ledger rig)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the sweep-ledger rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the sweep-ledger rig")
        }

        manager.startDeactivation(of: container)
        guard await settle(within: 5, until: { fake.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fake.saveCount))")
            return
        }
        let lingering = await TunnelsManager.awaitLingeringDisarmSave(on: fake, within: 0.5)
        guard check(!lingering,
                    "the ledger row is provably open before the sweep below runs") else { return }

        let tunnelId = container.id
        let sweep = Task { @MainActor in
            await manager.removeEntriesForUninstall([tunnelId])
        }
        _ = await settle(within: 2) { fake.removeCount > 0 }
        check(fake.removeCount == 0,
              "the sweep has not touched the system entry while the listed row's disarm save is in flight"
              + " — the ledger wait holds it, keyed by the row's own provider (removes=\(fake.removeCount))")

        fake.saveAnswer = .succeeds
        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
        let swept: Void? = await race(30) { await sweep.value }
        guard check(swept != nil, "the sweep finished once the save had landed") else { return }
        check(fake.removeCount == 1,
              "and the entry went exactly once, AFTER the landing — the two reads around the release are"
              + " the order (removes=\(fake.removeCount))")
        check(!fake.entryExists, "leaving the entry gone (entryExists=\(fake.entryExists))")

        let unlistedIdentity = TunnelIdentity(id: UUID(), name: "TE-Seam-SweepUnlisted-\(runTag)",
                                              createdAt: Date(), isGhost: false)
        let unlisted = FakeSlotProvider(name: unlistedIdentity.name, identity: unlistedIdentity,
                                        status: .disconnected)
        let bareManager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: FakeSlotFactory(canned: [unlisted]),
            vault: vault,
            observesSystemChanges: false
        )
        let unlistedSwept: Void? = await race(10) {
            await bareManager.removeEntriesForUninstall([unlistedIdentity.id])
        }
        check(unlistedSwept != nil && unlisted.removeCount == 1,
              "a row the list does not hold has no ledger entry to wait on — the sweep skips the wait and"
              + " the removal still goes out (removes=\(unlisted.removeCount))")
    }
}
#endif
