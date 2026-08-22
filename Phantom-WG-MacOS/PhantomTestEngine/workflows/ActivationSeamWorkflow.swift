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
// Activation Seam
//
// The activation machinery's interleavings, DRIVEN rather than waited for.
// Every step here measures a window a hand cannot aim at: a notification
// arriving mid-rung, a save that never answers, a removal and a queue
// hand-off racing for the same slot.
//
// The registered steps are the authority on coverage. Indicatively, the
// file covers the drop belts and the one revive, a list refresh that must
// disturb neither a running activation nor a queued turn, removals against
// the queue, the ceiling watchdog's withdrawals, the sweep and the stop
// reaching a rule the flag denies, give-up paths losing their rule, and
// the armed rule's own shape. A new step need not fit a name in this
// paragraph.
//
// The rig: one driven tunnel on a SIDE `TunnelsManager` over canned
// providers, brought to the point every belt scenario starts from —
// activation issued, `startTunnel` observed, session never connected.
//
// Reload triggers are OFF on that manager: a rig held open across a long
// window has no business being sent through a reload it did not ask for.
// The flag removes BOTH of this manager's reload triggers — a real
// configuration change anywhere in the system, and the app coming to the
// foreground — and either one would send it through `ingest`. The second
// is the one that could hit a rig held open while the user looks away.
// Every
// notification these steps care about is driven, and the status observer
// that carries it is not governed by the flag — what the flag removes is a
// real configuration change, anywhere in the system, sending this side
// manager through `ingest`, a pass that asks the REAL vault who owns each
// row.
//
// A step waits on an OBSERVED event wherever one exists: rung 0 rides a
// real vault verdict before it starts anything, so the observed start is
// the gate. Fixed sleeps appear only to spend a window an arrangement
// itself opened, never to stand in for an event a step could have watched.
//
// The family is split across three files at a type boundary rather than by
// moving a threshold — `+RuleOwnership` and `+Reset` are the same
// workflow, continued. The run tag and the shared `activatedRig` belong
// here; `+Reset` builds the driven variant on top of it, and the polling
// helper lives on `TestWorkflow`.

#if DEBUG
import Foundation
import NetworkExtension

final class ActivationSeamWorkflow: TestWorkflow {
    override var displayName: String { "Activation Seam (Driven Interleavings)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Removal Bars A Queued Disarm Save", disarmDuringRemoval),
            WorkflowStep("Belt Files A System Record As The Failure", beltFilesRecord),
            WorkflowStep("Belt Spends The One Revive On A Silent Drop", beltSpendsRevive),
            WorkflowStep("Spent Revive Still Leaves An Error Behind", beltStandInAfterSpentRevive),
            WorkflowStep("Belt Does Not Write Over A Revived Session", beltRespectsRevivedSession),
            WorkflowStep("A Stop Cannot Be Answered With A Start", stopBeatsInFlightSave),
            WorkflowStep("A Refused Disarm Surfaces And The Stop Still Lands", refusedDisarmSurfaces),
            WorkflowStep("A List Refresh Cannot Cancel An Activation", refreshCannotCancelActivation),
            WorkflowStep("A List Refresh Cannot Take A Queued Tunnel's Turn", refreshCannotDropTheQueue),
            WorkflowStep("An .invalid Occupant Does Not Hand On The Queue",
                         anInvalidOccupantDoesNotHandOnTheQueue),
            WorkflowStep("A Flicker Back To .invalid Is Still Not An Answer",
                         aFlickerBackToInvalidIsStillNotAnAnswer),
            WorkflowStep("A Transient Does Not Repaint A Held Row",
                         aTransientDoesNotRepaintAHeldRow),
            WorkflowStep("A Stop Nobody Answers Grounds Its Own Row",
                         aStopNobodyAnswersGroundsItsOwnRow),
            WorkflowStep("An Armed .invalid Occupant Does Not Hand On The Queue Either",
                         anArmedInvalidOccupantDoesNotHandOnTheQueue),
            WorkflowStep("A Ceiling Does Not Ground A Row The List No Longer Holds",
                         aCeilingDoesNotGroundARowTheListNoLongerHolds),
            WorkflowStep("A Removal Hands The Queue On Only When The Slot Is Free", removalHandsOnTheQueue),
            WorkflowStep("A Queue Slot Whose Tunnel Left The List Is Discarded", staleQueueSlotIsDiscarded),
            WorkflowStep("A Teardown Holding The Store Takes No Hand-Off",
                         aTeardownHoldingTheStoreTakesNoHandOff),
            WorkflowStep("A Teardown Holding The Store Arms Nothing",
                         aTeardownHoldingTheStoreArmsNothing),
            WorkflowStep("A Rung Already Past The Entry Arms Nothing Either",
                         aRungAlreadyPastTheEntryArmsNothingEither),
            WorkflowStep("A Row The List Dropped Raises No Session Either",
                         aRowTheListDroppedRaisesNoSessionEither),
            WorkflowStep("An Attempt That Never Resolves Is Withdrawn", wedgedAttemptIsWithdrawn),
            WorkflowStep("A Withdrawal Leaves The Dying Session To The System", dyingSessionIsWithdrawnInPlace),
            WorkflowStep("A Grounded Row Cannot Silence Its Own Attempt", groundedRowIsStillWithdrawn),
            WorkflowStep("The Sweep Reaches A Rule The Flag Denies", sweepReachesAStoreOnlyRule),
            WorkflowStep("A Stop Reaches A Rule The Flag Denies", stopReachesAStoreOnlyRule),
            WorkflowStep("A Revived Session Sheds The Failed Attempt's Verdict", revivalClearsTheVerdict),
            WorkflowStep("A Give-Up Does Not Ground A Session The System Holds", giveUpDoesNotGroundALiveSession),
            WorkflowStep("The Watchdog Leaves A Rising Session Alone", peekLeavesARisingSessionAlone),
            WorkflowStep("A Config That Will Not Load Loses Its Rule", loadFailureStandsTheRuleDown),
            WorkflowStep("A Start The System Refuses Loses Its Rule", startFailureStandsTheRuleDown),
            WorkflowStep("A Second Removal Is A Silent No-Op", secondRemovalIsASilentNoOp),
            WorkflowStep("The Delete Flow's Stop Cannot Outrun Its Removal", deleteFlowStopCannotOutrunItsRemoval),
            WorkflowStep("The Armed Rule Is One Connect Rule For Any Interface",
                         theArmedRuleIsOneConnectRuleForAnyInterface),
            WorkflowStep("A Reset's Outcome Byte Decides The Caller's Verdict",
                         resetOutcomeByteDecidesTheVerdict),
            WorkflowStep("A Reset Nobody Answers Ends Its Own Wait",
                         resetNobodyAnswersEndsItsOwnWait),
            WorkflowStep("A Stop On An Armed Row Is Visible While It Waits",
                         stopOnAnArmedRowIsVisibleWhileItWaits),
            WorkflowStep("A Landed Stop Stops Claiming To Be Under Way",
                         aLandedStopStopsClaimingToBeUnderWay),
        ]
    }

    let runTag = String(UUID().uuidString.prefix(8))

    // MARK: - Shared rig

    func activatedRig(
        name: String,
        configure: (FakeSlotProvider) -> Void
    ) async -> (fake: FakeSlotProvider, manager: TunnelsManager, container: TunnelContainer)? {
        let identity = TunnelIdentity(id: UUID(), name: name, createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)
        configure(fake)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize \(name)")
            return nil
        }
        manager.startActivation(of: container)
        let start = Date()
        while Date().timeIntervalSince(start) < 8 {
            if fake.startCount >= 1 { return (fake, manager, container) }
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        skip("environment: the rig's activation never reached startTunnel (vault verdict too slow?)")
        return nil
    }

    // MARK: - Steps

    private func disarmDuringRemoval() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Remove-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .connected)
        fake.isEnabled = true
        fake.arrangeArmed()
        fake.removeAnswer = .succeedsAfter(seconds: 3)

        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the seam tunnel")
            return
        }

        let savesBefore = fake.saveCount
        let removal = Task { @MainActor in
            (try? await manager.remove(tunnel: container)) != nil
        }

        var barred = false
        let start = Date()
        while Date().timeIntervalSince(start) < 5 {
            if manager.removingIds.contains(identity.id) { barred = true; break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard barred else {
            _ = await removal.value
            skip("environment: removal never reached its in-flight window")
            return
        }

        manager.startDeactivation(of: container)

        try? await Task.sleep(for: .milliseconds(600))
        check(fake.saveCount - savesBefore <= 1,
              "at most the removal's own stand-down has written (saves \(savesBefore) → \(fake.saveCount))")
        guard await settle(within: 3, until: { fake.saveCount > savesBefore }) else {
            _ = await removal.value
            skip("environment: the removal never reached its own stand-down (vault slow?)")
            return
        }
        check(!fake.storedOnDemand,
              "the rule left the STORE before the entry did — the stand-down landed first (store=\(fake.storedOnDemand), removes=\(fake.removeCount))")

        guard await removal.value else {
            skip("environment: removal itself failed (vault dark?) — bar semantics unproven this run")
            return
        }

        check(fake.saveCount - savesBefore == 1,
              "exactly one save total — remove()'s own stand-down; the queued stop-disarm stayed barred (saves=\(fake.saveCount))")
        check(!fake.isOnDemandEnabled,
              "the rule ended down — stood down by the removal before the entry went")
        check(fake.removeCount == 1, "the entry was removed exactly once (removePreferences=\(fake.removeCount))")
        check(manager.tunnels.contains(where: { $0.id == identity.id }) == false,
              "the tunnel left the list")

        let savesAtEnd = fake.saveCount
        try? await Task.sleep(for: .milliseconds(400))
        check(fake.saveCount == savesAtEnd,
              "no preferences save landed after the entry was deleted (saves=\(fake.saveCount))")
        check(!fake.entryExists,
              "and the entry stayed gone rather than being re-minted (entryExists=\(fake.entryExists))")
    }

    private func beltFilesRecord() async {
        let record = NSError(domain: "TE.Seam", code: 41,
                             userInfo: [NSLocalizedDescriptionKey: "driven start failure"])
        guard let rig = await activatedRig(name: "TE-Seam-Record-\(runTag)", configure: {
            $0.disconnectAnswer = .record(record)
        }) else { return }
        rig.fake.drive(.disconnected)
        let landed = await settle(within: 6) { rig.container.lastActivationError != nil }
        check(landed, "the drop was explained — lastActivationError=\(rig.container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        var filedTheRecord = false
        if case .failedWhileActivating(let sys) = rig.container.lastActivationError {
            filedTheRecord = (sys as NSError).domain == record.domain && (sys as NSError).code == record.code
        }
        check(filedTheRecord, "the SYSTEM's record was filed, not a stand-in")
        try? await Task.sleep(for: .seconds(2))
        check(rig.fake.startCount == 1, "no retry was spent on an explained failure (starts=\(rig.fake.startCount))")
    }

    private func beltSpendsRevive() async {
        guard let rig = await activatedRig(name: "TE-Seam-Revive-\(runTag)", configure: {
            $0.disconnectAnswer = .none
        }) else { return }
        rig.fake.drive(.disconnected)
        let revived = await settle(within: 12) { rig.fake.startCount >= 2 }
        if !revived {
            if case .unreachable = await vault.ping() {
                skip("environment: vault dark during the belt's verdict leg — revive timing unprovable this run")
                return
            }
        }
        check(revived, "the one revive restarted the tunnel (starts=\(rig.fake.startCount))")
        check(rig.container.respawnReviveConsumed, "the revive is marked spent")
    }

    private func beltStandInAfterSpentRevive() async {
        guard let rig = await activatedRig(name: "TE-Seam-StandIn-\(runTag)", configure: {
            $0.disconnectAnswer = .never
        }) else { return }
        onTeardown("held disconnect fetch") { [weak self] in
            let released = rig.fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: no held fetch remained"
                      : "teardown: released \(released) held fetch completion(s)")
        }
        rig.container.respawnReviveConsumed = true
        rig.fake.drive(.disconnected)
        let explained = await settle(within: 10) { rig.container.lastActivationError != nil }
        if !explained {
            guard rig.manager.tunnels.contains(where: { $0 === rig.container }) else {
                fail("the rig's row left its own list mid-step — the belt had nothing to write to,"
                     + " and nothing should have been able to take it")
                return
            }
            if case .unreachable = await vault.ping() {
                skip("environment: vault dark during the belt's verdict leg — stand-in timing unprovable this run")
                return
            }
        }
        check(explained, "a mute system still left an error behind — lastActivationError=\(rig.container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(rig.fake.startCount == 1, "and no retry was invented (starts=\(rig.fake.startCount))")
    }

    private func beltRespectsRevivedSession() async {
        guard let rig = await activatedRig(name: "TE-Seam-Green-\(runTag)", configure: {
            $0.disconnectAnswer = .recordAfter(seconds: 2, NSError(domain: "TE.Seam", code: 42))
        }) else { return }
        rig.container.respawnReviveConsumed = true
        rig.fake.drive(.disconnected)
        try? await Task.sleep(for: .milliseconds(300))
        rig.fake.drive(.connected)
        guard await settle(within: 3, until: { rig.container.status == .active }) else {
            fail("the driven revival never reached the handler — status=\(rig.container.status)")
            return
        }
        try? await Task.sleep(for: .milliseconds(3200))
        check(rig.container.lastActivationError == nil,
              "no failure was written under the revived session — error=\(rig.container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(rig.container.status == .active, "the session stayed green — status=\(rig.container.status)")
    }

    private func stopBeatsInFlightSave() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Stop-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        fake.saveAnswer = .succeedsAfter(seconds: 1.5)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the stop-rig tunnel")
            return
        }
        manager.startActivation(of: container)
        guard await settle(within: 8, until: { fake.saveCount >= 1 }) else {
            skip("environment: the rung never reached its arm save")
            return
        }
        manager.startDeactivation(of: container)
        try? await Task.sleep(for: .milliseconds(2500))
        check(fake.startCount == 0, "startTunnel was never called past the stop (starts=\(fake.startCount))")
        check(!fake.isOnDemandEnabled && !fake.storedOnDemand,
              "the recovery rule ended disarmed where it counts — in the store (flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand))")
        check(container.lastActivationError == nil,
              "the stop wears no error — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        let grounded = await settle(within: 3) { container.status == .inactive }
        check(grounded, "the row settled inactive — status=\(container.status)")
    }

    private func refusedDisarmSurfaces() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Refused-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .connected)
        fake.isEnabled = true
        fake.arrangeArmed()
        fake.saveAnswer = .fails(NSError(domain: "TE.Seam", code: 43,
                                         userInfo: [NSLocalizedDescriptionKey: "driven save refusal"]))
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the refused-disarm tunnel")
            return
        }
        let loadsBefore = fake.loadCount
        manager.startDeactivation(of: container)

        let stopped = await settle(within: 3) { fake.stopCount >= 1 }
        check(stopped, "the stop still went out past the refused save (stops=\(fake.stopCount))")
        var surfaced = false
        if case .stopDisarmRefused = container.lastActivationError { surfaced = true }
        check(surfaced, "the refusal surfaced as stopDisarmRefused, the case whose sentence names the rule and the revival rather than a configuration save — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(fake.loadCount > loadsBefore,
              "the refusal ASKED the store rather than reporting the value it had just written (loads=\(fake.loadCount), before=\(loadsBefore))")
        check(fake.isOnDemandEnabled && fake.storedOnDemand,
              "and the flag carries that answer — still armed — rather than the comfortable half (flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand))")

        fake.drive(.disconnected)
        let grounded = await settle(within: 3) { container.status == .inactive }
        check(grounded, "the row settled inactive once the session answered — status=\(container.status)")
    }

    private func refreshCannotCancelActivation() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Refresh-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        fake.saveAnswer = .succeedsAfter(seconds: 1.5)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the refresh-rig tunnel")
            return
        }
        manager.startActivation(of: container)
        guard await settle(within: 8, until: { fake.saveCount >= 1 }) else {
            skip("environment: the rung never reached its arm save")
            return
        }
        container.refreshStatus()
        check(container.status == .activating,
              "a .disconnected refresh left the attempt alone — status=\(container.status)")

        fake.setStatusSilently(.invalid)
        container.refreshStatus()
        check(container.status == .activating,
              "an .invalid refresh left the attempt alone — status=\(container.status)")

        fake.setStatusSilently(.disconnecting)
        container.refreshStatus()
        check(container.status == .activating,
              "a .disconnecting refresh left the attempt alone — status=\(container.status)")

        let started = await settle(within: 6) { fake.startCount >= 1 }
        check(started, "the activation still reached startTunnel (starts=\(fake.startCount))")

        check(container.isManagerDriven,
              "the row is still manager-driven, so the claim below has something to prove")
        fake.setStatusSilently(.connected)
        container.refreshStatus()
        check(container.status == .active,
              "a .connected refresh still landed — status=\(container.status)")
    }

    private func refreshCannotDropTheQueue() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-QueueA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-QueueB-\(runTag)", createdAt: Date(), isGhost: false)
        let idC = TunnelIdentity(id: UUID(), name: "TE-Seam-QueueC-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .connected)
        fakeA.isEnabled = true
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .disconnected)
        let fakeC = FakeSlotProvider(name: idC.name, identity: idC, status: .disconnected)
        fakeC.arrangeArmed()

        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB, fakeC],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB, fakeC]),
            vault: vault
        )
        guard let a = manager.tunnels.first(where: { $0.id == idA.id }),
              let b = manager.tunnels.first(where: { $0.id == idB.id }) else {
            fail("side manager did not materialize the queue rig")
            return
        }
        guard a.status == .active else {
            fail("the rig's first tunnel did not start active — status=\(a.status)")
            return
        }

        manager.startActivation(of: b)
        guard b.status == .waiting else {
            fail("the second tunnel did not queue behind the first — status=\(b.status)")
            return
        }

        b.refreshStatus()
        check(b.status == .waiting, "the queue slot survived a list refresh — status=\(b.status)")

        fakeB.setStatusSilently(.disconnecting)
        b.refreshStatus()
        check(b.status == .waiting,
              "a .disconnecting refresh left the queue slot alone — status=\(b.status)")

        fakeB.drive(.disconnected)
        var slotHeld = true
        let watch = Date()
        while Date().timeIntervalSince(watch) < 0.5 {
            if b.status != .waiting { slotHeld = false; break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        check(slotHeld && b.status == .waiting,
              "a driven .disconnected notification left the queue slot alone — status=\(b.status)")

        fakeA.drive(.disconnected)
        let tookItsTurn = await settle(within: 12) { fakeB.startCount >= 1 }
        if !tookItsTurn, !manager.tunnels.contains(where: { $0.id == idB.id }) {
            skip("environment: a refresh emptied the side manager's list mid-step")
            return
        }
        check(tookItsTurn, "the queued tunnel took its turn (starts=\(fakeB.startCount))")
        let sweptC = await settle(within: 5) { !fakeC.storedOnDemand }
        check(sweptC && !fakeC.isOnDemandEnabled,
              "the hand-off disarmed the idle armed tunnel where it counts — in the store (store=\(fakeC.storedOnDemand), flag=\(fakeC.isOnDemandEnabled))")
    }

    private func removalHandsOnTheQueue() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-RemA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-RemB-\(runTag)", createdAt: Date(), isGhost: false)
        let idC = TunnelIdentity(id: UUID(), name: "TE-Seam-RemC-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .connected)
        fakeA.isEnabled = true
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .disconnected)
        let fakeC = FakeSlotProvider(name: idC.name, identity: idC, status: .disconnected)

        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB, fakeC],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB, fakeC]),
            vault: vault
        )
        guard let a = manager.tunnels.first(where: { $0.id == idA.id }),
              let b = manager.tunnels.first(where: { $0.id == idB.id }),
              let c = manager.tunnels.first(where: { $0.id == idC.id }) else {
            fail("side manager did not materialize the removal rig")
            return
        }

        manager.startActivation(of: b)
        guard b.status == .waiting else {
            fail("the second tunnel did not queue behind the first — status=\(b.status)")
            return
        }

        fakeA.setStatusSilently(.disconnecting)

        guard (try? await manager.remove(tunnel: c)) != nil else {
            skip("environment: removing the bystander failed (vault dark?)")
            return
        }
        guard manager.tunnels.contains(where: { $0.id == idB.id }) else {
            skip("environment: a refresh emptied the side manager's list mid-step")
            return
        }
        check(manager.tunnels.contains(where: { $0.id == idC.id }) == false, "the bystander left the list")
        check(manager.waitingTunnel === b, "the slot itself is still held for B")
        let startedEarly = await settle(within: 1) { fakeB.startCount > 0 }
        check(!startedEarly,
              "the removal did not start the queued tunnel over a session the manager still shows as going down (starts=\(fakeB.startCount))")
        check(b.status == .waiting, "and the queue slot survived the removal — status=\(b.status)")

        guard (try? await manager.remove(tunnel: a)) != nil else {
            skip("environment: removing the blocker failed (vault dark?)")
            return
        }
        let tookItsTurn = await settle(within: 12) { fakeB.startCount >= 1 }
        if !tookItsTurn, !manager.tunnels.contains(where: { $0.id == idB.id }) {
            skip("environment: a refresh emptied the side manager's list mid-step")
            return
        }
        check(tookItsTurn,
              "removing the blocker handed the queue on with no notification in sight (starts=\(fakeB.startCount))")
    }

    private func staleQueueSlotIsDiscarded() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-StaleA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-StaleB-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .connected)
        fakeA.isEnabled = true
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .disconnected)

        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB]),
            vault: vault
        )
        guard let b = manager.tunnels.first(where: { $0.id == idB.id }) else {
            fail("side manager did not materialize the stale-slot rig")
            return
        }
        manager.startActivation(of: b)
        guard b.status == .waiting, manager.waitingTunnel === b else {
            fail("the rig did not park a queue slot — status=\(b.status)")
            return
        }
        fakeA.setStatusSilently(.disconnecting)

        await manager.refresh()
        guard manager.tunnels.contains(where: { $0.id == idB.id }) == false else {
            skip("environment: the reload kept the unbacked row, so there is no stale slot to discard")
            return
        }

        check(b.status == .waiting, "the unlisted row was left alone — status=\(b.status)")
        check(manager.waitingTunnel == nil, "and the stale slot was discarded rather than kept")
        let started = await settle(within: 1) { fakeB.startCount > 0 }
        check(!started, "no session was raised for a row the list no longer holds (starts=\(fakeB.startCount))")
    }

    private func wedgedAttemptIsWithdrawn() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Wedged-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        fake.saveAnswer = .hangs
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            retryInterval: 1.0,
            maxRetries: 2,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the wedged-attempt tunnel")
            return
        }
        onTeardown("wedged save") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: nothing was still held — the step released the wedge itself"
                      : "teardown: released \(released) held request(s) so the side manager can go")
        }

        manager.startActivation(of: container)
        guard await settle(within: 8, until: { fake.saveCount >= 1 }) else {
            skip("environment: the rung never reached its arm save")
            return
        }
        let savesAtArm = fake.saveCount
        check(container.status == .activating,
              "the attempt is wedged inside a save that will never answer — status=\(container.status)")

        let explained = await settle(within: 8) { container.lastActivationError != nil }
        check(explained,
              "the ceiling withdrew it — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        var named = false
        if case .activationUnresolved = container.lastActivationError { named = true }
        check(named, "and said the system never answered rather than inventing an error it did not give")
        check(container.status == .inactive, "the row came back to rest — status=\(container.status)")
        check(!container.isAttemptingActivation, "the attempt flag came down with it")

        let window = manager.preflightBudget + manager.retryInterval
        let climbedAgain = await settle(within: window) { fake.saveCount > savesAtArm + 1 }
        check(!climbedAgain && fake.saveCount == savesAtArm + 1,
              "exactly the arm save and the withdrawal's own stand-down (saves=\(fake.saveCount), expected \(savesAtArm + 1))")

        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")

        let savesAfterRelease = fake.saveCount
        let climbedAfterRelease = await settle(within: manager.preflightBudget + 0.5) {
            fake.saveCount > savesAfterRelease
        }
        check(!climbedAfterRelease,
              "and nothing climbed once the wedge was released (saves=\(fake.saveCount))")
        var verdictKept = false
        if case .activationUnresolved = container.lastActivationError { verdictKept = true }
        check(verdictKept,
              "the late save's refusal could not overwrite the withdrawal's verdict — error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
    }

    private func dyingSessionIsWithdrawnInPlace() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Dying-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            retryInterval: 1.0,
            maxRetries: 2,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the dying-session tunnel")
            return
        }
        onTeardown("held completions (dying-session step)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: nothing was held, as this rig intends"
                      : "teardown: released \(released) held request(s)")
        }

        manager.startActivation(of: container)
        fake.drive(.disconnecting)
        let dying = await settle(within: 2) {
            container.status == .deactivating && container.isAttemptingActivation
        }
        check(dying, "the session is dying under an attempt that still holds its intent — status=\(container.status)")
        let savesBeforeWithdrawal = fake.saveCount

        let explained = await settle(within: 8) { container.lastActivationError != nil }
        check(explained,
              "the ceiling withdrew it — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        var named = false
        if case .activationUnresolved = container.lastActivationError { named = true }
        check(named, "and said the system never answered rather than inventing an error it did not give")
        check(!container.isAttemptingActivation, "the attempt flag came down")
        check(container.status == .deactivating,
              "the dying session was left to the system — status=\(container.status)")
        let window = manager.preflightBudget + manager.retryInterval
        let climbed = await settle(within: window) {
            fake.saveCount > savesBeforeWithdrawal + 1 || fake.startCount > 0
        }
        check(!climbed && fake.saveCount == savesBeforeWithdrawal + 1,
              "exactly the withdrawal's own stand-down (saves=\(fake.saveCount), expected \(savesBeforeWithdrawal + 1))")
        check(fake.startCount == 0,
              "no session was ever raised over the dying one (starts=\(fake.startCount))")

        fake.drive(.disconnected)
        let grounded = await settle(within: 2) { container.status == .inactive }
        check(grounded, "the system's own .disconnected grounded the row once it finally came — status=\(container.status)")
        var explanationSurvived = false
        if case .activationUnresolved = container.lastActivationError { explanationSurvived = true }
        check(explanationSurvived, "and the withdrawal's explanation survived the grounding")
    }
}
#endif
