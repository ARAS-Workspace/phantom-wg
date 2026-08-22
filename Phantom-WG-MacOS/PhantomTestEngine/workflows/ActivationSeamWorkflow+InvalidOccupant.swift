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
// Activation Seam — The Occupant Whose Stop Answered .invalid
//
// Steps belonging to `ActivationSeamWorkflow`; the registry lives in the
// main file. One subject: what happens to the VPN slot when a stop is
// answered `.invalid`, the one reading that cannot tell a session that
// ended from one that is very much alive in the moment after a save.
//
// The slot is single. Handing it on over a session still going down is
// the outcome nothing recovers from, so the row is HELD at `.deactivating`
// until the system says something definite, and a ceiling ends that hold
// on its own budget rather than leaving a row stopping for ever.
//
// Scenarios:
//
//   A — An .invalid Occupant Does Not Hand On The Queue
//       The hold, from three angles: the synchronous stop, a NOTIFICATION
//       that still reads `.invalid` (which the observer would otherwise
//       repaint through), and the system's own `.disconnected`, which is
//       the only thing that hands the queue on.
//
//   B — A Stop Nobody Answers Grounds Its Own Row
//       The other half of the hold. Nothing ever answers, and the ceiling
//       ends the wait itself.
//
//   C — An Armed .invalid Occupant Does Not Hand On The Queue Either
//       The same claim on the path a user actually takes most often,
//       where `performDeactivation` runs inside a parked disarm task
//       rather than inside the caller.
//
//   D — A Transient Does Not Repaint A Held Row
//       The hold is only as good as the reading that may end it. A held row
//       used to refuse `.invalid` alone, so `.reasserting` and `.connecting`
//       repainted it to a live-looking status and the ceiling then failed
//       its own `.deactivating` guard and stood down without grounding
//       anything. Both the hold's bar and the ceiling's release now read one
//       predicate — `NEVPNStatus.isTerminalAnswer` — so they cannot drift
//       apart. The step's control comes LAST and reuses the SAME drive: once
//       the terminal answer has taken the backstop away, a second
//       `.reasserting` repaints the row, which is what says the readings
//       above were barred rather than never delivered.
//
//   E — A Late .invalid Does Not Hand On The Queue Either
//       The hold used to be armed from ONE door: the synchronous reading
//       taken right after `stopTunnel()`. But that call is asynchronous, so
//       a live session still reads `.connected` there and takes the plain
//       `default` arm — no ceiling. The `.invalid` then arrives as a
//       NOTIFICATION, finds no ceiling to bar it, grounds the row and hands
//       the slot on: the exact hand-off this file exists to prevent, on the
//       door a real session actually walks through. Every run of this suite
//       says so — the arming log fires only for the driven `TE-Seam-*` rows
//       and never once for a real tunnel. The notification door now answers
//       `.invalid` the way the synchronous one does, and the ceiling it
//       arms is both the fix and the step's proof that the reading was
//       delivered at all.
//
//   F — An .invalid While The Stop Waits On Its Rule Holds Too
//       E keyed the notification hold on `.deactivating`, and an ARMED
//       occupant is not `.deactivating` yet: its stop parks on its own
//       disarm save and the row stays `.active` until `performDeactivation`
//       runs inside that parked task. An `.invalid` landing in THAT window
//       walked straight past E's guard and grounded a live row. The row
//       already names the window — `stopIsWaitingOnItsRule` — so the hold
//       reads it rather than inventing a second notion of "stopping". The
//       row is taken into `.deactivating` as it is held, because a ceiling
//       that cannot see the hold in the status cannot end it on budget.
//
//   G — A Terminal Reading Ends The Hold Wherever It Is Read
//       The hold was released on a terminal answer only where the observer
//       handled one. A list refresh reads the same answer through
//       `refreshStatus` and used to repaint the row while leaving the
//       ceiling armed behind it — a ceiling outliving its hold, free to
//       suppress a later reading in a give-up it has nothing to do with.
//       The release now lives with the reading, not with the door.
//
//   H — A Teardown Takes The Ceilings It Finds
//       The uninstall sweep took every deferred task except this one. And
//       taking a backstop is only half the job: whatever it would have
//       done still has to happen, or the row is left stopping for ever,
//       holding the single slot against every tunnel including itself.
//
//   I — A Hold That May Not Arm Still Refuses To Ground
//       The bar on arming was first written as one more condition on the
//       hold's own `if`, which quietly made a barred hold fall through to
//       the grounding it exists to prevent. Refusing to arm and deciding
//       the question are different acts: the reading is still not an
//       answer, whoever may or may not write. The gate now lives inside
//       `armGroundingCeiling`, where every door reaches it, and the hold
//       returns whether or not a ceiling was armed.
//
// What this file cannot prove is which of the two things `.invalid` meant.
// Nothing can, at the moment it is read — that is the whole reason the
// hold exists. What is proven is that the app stops guessing.

#if DEBUG
import Foundation
import NetworkExtension

extension ActivationSeamWorkflow {

    func invalidQueueRig(_ label: String) -> (
        fakeA: FakeSlotProvider, fakeB: FakeSlotProvider,
        a: TunnelContainer, b: TunnelContainer, manager: TunnelsManager
    )? {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-\(label)A-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-\(label)B-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .connected)
        fakeA.isEnabled = true
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .disconnected)

        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let a = manager.tunnels.first(where: { $0.id == idA.id }),
              let b = manager.tunnels.first(where: { $0.id == idB.id }) else {
            fail("side manager did not materialize the queue rig")
            return nil
        }
        guard a.status == .active else {
            fail("the rig's occupant did not start active — status=\(a.status)")
            return nil
        }
        return (fakeA, fakeB, a, b, manager)
    }

    func anInvalidOccupantDoesNotHandOnTheQueue() async {
        guard let rig = invalidQueueRig("Invalid") else { return }

        check(!rig.a.isActivateOnDemandEnabled,
              "the occupant is UNARMED, which is what makes its stop run inside the caller rather than a parked task")

        rig.fakeA.setStatusSilently(.invalid)
        rig.manager.startActivation(of: rig.b)

        check(rig.fakeA.stopCount == 1,
              "the stop reached the occupant — stops=\(rig.fakeA.stopCount), expected 1")
        check(rig.a.status == .deactivating,
              "and the row is HELD at deactivating rather than grounded flat, because .invalid cannot tell a finished"
              + " session from a live one — status=\(rig.a.status)")

        let startedEarly = await settle(within: 1) { rig.fakeB.startCount > 0 }
        check(!startedEarly,
              "so no session was raised over it (starts=\(rig.fakeB.startCount))")

        rig.fakeA.setStatusSilently(.invalid)
        rig.fakeA.drive(.invalid)
        let startedOnEcho = await settle(within: 1) { rig.fakeB.startCount > 0 }
        check(!startedOnEcho,
              "and a NOTIFICATION that still reads .invalid is not an answer either — the observer's own repaint is"
              + " barred while the ceiling stands (starts=\(rig.fakeB.startCount))")
        check(rig.a.status == .deactivating,
              "the row is still held — status=\(rig.a.status)")

        rig.fakeA.drive(.disconnected)
        let tookItsTurn = await settle(within: 3) { rig.fakeB.startCount >= 1 }
        check(tookItsTurn,
              "but the system's OWN answer hands the queue on — starts=\(rig.fakeB.startCount), expected 1")
        check(rig.a.status == .inactive,
              "with the occupant grounded on that answer rather than on a guess — status=\(rig.a.status)")
    }

    func aFlickerBackToInvalidIsStillNotAnAnswer() async {
        guard let rig = invalidQueueRig("Flicker") else { return }

        rig.fakeA.setStatusSilently(.invalid)
        rig.manager.startActivation(of: rig.b)
        guard check(rig.a.status == .deactivating,
                    "the occupant is held on the reading that cannot answer — status=\(rig.a.status)") else { return }

        guard check(rig.a.isHoldingForAnAnswer,
                    "with a backstop standing behind that hold") else { return }

        rig.fakeA.drive(.disconnecting)
        _ = await settle(within: 0.5) { !rig.a.isHoldingForAnAnswer }
        check(rig.a.isHoldingForAnAnswer,
              "a .disconnecting says the system is WORKING on it, not that it is done, so it does NOT take the"
              + " backstop away — which is the whole reason the reading below still has a guard to meet")
        check(rig.a.status == .deactivating,
              "and the row is still held — status=\(rig.a.status)")

        rig.fakeA.drive(.invalid)
        let startedOnFlicker = await settle(within: 0.5) { rig.fakeB.startCount > 0 }
        check(!startedOnFlicker,
              "and when the reading FLICKERS BACK to .invalid the hold is still standing, because the transient"
              + " never took the backstop away (starts=\(rig.fakeB.startCount))")
        check(rig.a.status == .deactivating,
              "so the row was not repainted out from under it — status=\(rig.a.status)")

        guard check(rig.a.isHoldingForAnAnswer,
                    "the backstop has still not spent its budget, so what hands the queue on below is the ANSWER"
                    + " rather than the ceiling running out under a slow rig") else { return }

        rig.fakeA.drive(.disconnected)
        let tookItsTurn = await settle(within: 3) { rig.fakeB.startCount >= 1 }
        check(tookItsTurn,
              "only the TERMINAL answer hands the queue on — starts=\(rig.fakeB.startCount), expected 1")
        check(rig.a.status == .inactive,
              "with the occupant grounded on it — status=\(rig.a.status)")
    }

    func aStopNobodyAnswersGroundsItsOwnRow() async {
        guard let rig = invalidQueueRig("Ceiling") else { return }

        rig.fakeA.setStatusSilently(.invalid)
        rig.manager.startActivation(of: rig.b)

        guard rig.a.status == .deactivating else {
            fail("the rig never reached the held state the ceiling is supposed to end — status=\(rig.a.status)")
            return
        }
        let budget = TunnelsManager.groundingBudget
        let early = await settle(within: max(1, budget - 1.5)) { rig.fakeB.startCount > 0 }
        check(!early,
              "the row is still held part-way through the budget (starts=\(rig.fakeB.startCount))")

        let grounded = await settle(within: budget + 3) { rig.a.status == .inactive }
        check(grounded,
              "and nothing answered, so the ceiling ended the wait on its own budget rather than holding for ever"
              + " — status=\(rig.a.status)")
        let tookItsTurn = await settle(within: 3) { rig.fakeB.startCount >= 1 }
        check(tookItsTurn,
              "handing the slot to the queued tunnel as it went — starts=\(rig.fakeB.startCount), expected 1")
    }

    func aCeilingDoesNotGroundARowTheListNoLongerHolds() async {
        let nameA = "TE-Seam-DroppedA-\(runTag)"
        let nameB = "TE-Seam-DroppedB-\(runTag)"
        guard let cfgA = TestConfigFactory.throwaway(name: nameA),
              let cfgB = TestConfigFactory.throwaway(name: nameB) else {
            fail("could not build the dropped-row configs")
            return
        }
        let idA = TunnelIdentity(id: cfgA.id, name: nameA, createdAt: cfgA.createdAt, isGhost: false)
        let idB = TunnelIdentity(id: cfgB.id, name: nameB, createdAt: cfgB.createdAt, isGhost: false)
        let fakeA = FakeSlotProvider(name: nameA, identity: idA, status: .connected)
        fakeA.isEnabled = true
        let fakeB = FakeSlotProvider(name: nameB, identity: idB, status: .disconnected)

        // The pass below runs a real ingest, so the vault has to own both ids
        // or it would drop the queued row along with the one under test.
        let faultVault = FaultVaultClient()
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.readAllAnswer = .answers(.configs([cfgA, cfgB]))
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        // The list is seeded with BOTH rows, but the factory only ever knows
        // about the queued one — so the pass below drops the occupant without
        // anything having to be removed from a store first.
        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB],
            providerFactory: FakeSlotFactory(canned: [fakeB]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let a = manager.tunnels.first(where: { $0.id == idA.id }),
              let b = manager.tunnels.first(where: { $0.id == idB.id }), a.status == .active else {
            fail("side manager did not materialize the dropped-row rig")
            return
        }

        fakeA.setStatusSilently(.invalid)
        manager.startActivation(of: b)
        guard check(a.status == .deactivating && a.isHoldingForAnAnswer,
                    "the occupant is held with a backstop behind it — status=\(a.status)") else { return }

        await manager.prune()

        guard check(!manager.tunnels.contains(where: { $0 === a }),
                    "the list dropped the row while its ceiling was still standing, which is the arrangement the"
                    + " guard below is for — rows=\(manager.tunnels.count)") else { return }
        guard check(manager.tunnels.contains(where: { $0 === b }),
                    "and it kept the queued one, so the slot below is still a slot") else { return }
        guard check(a.isHoldingForAnAnswer,
                    "with the dropped row's ceiling still armed — nothing cancelled it on the way out, which is"
                    + " exactly the forgotten-cancel this guard stands in for") else { return }
        guard check(a.status == .deactivating,
                    "and nothing else has repainted it, so the ceiling is the only thing that could —"
                    + " status=\(a.status)") else { return }
        guard check(manager.waitingTunnel === b,
                    "with the queue slot still held, so a hand-off from the ceiling would be visible") else { return }

        let moved = await settle(within: TunnelsManager.groundingBudget + 3) { a.status != .deactivating }
        check(!moved,
              "the ceiling spent its budget and stood down rather than grounding a row this manager no longer"
              + " holds — status=\(a.status)")
        check(fakeB.startCount == 0,
              "so it handed the slot to nobody either — starts=\(fakeB.startCount), expected 0")
    }

    func anArmedInvalidOccupantDoesNotHandOnTheQueue() async {
        guard let rig = invalidQueueRig("ArmedInvalid") else { return }
        rig.fakeA.arrangeArmed()
        guard rig.a.isActivateOnDemandEnabled else {
            fail("the rig's occupant is not armed, so this step would drive the unarmed path its sibling already covers")
            return
        }

        rig.fakeA.setStatusSilently(.invalid)
        rig.manager.startActivation(of: rig.b)

        let held = await settle(within: 3) { rig.a.status == .deactivating }
        check(held,
              "the ARMED path holds its occupant the same way, once its parked disarm reaches the stop —"
              + " status=\(rig.a.status)")
        check(rig.fakeA.stopCount == 1,
              "with the stop issued exactly once from that parked task (stops=\(rig.fakeA.stopCount))")
        let startedEarly = await settle(within: 1) { rig.fakeB.startCount > 0 }
        check(!startedEarly,
              "and no session was raised over it (starts=\(rig.fakeB.startCount))")
    }

    func aTransientDoesNotRepaintAHeldRow() async {
        guard let rig = invalidQueueRig("Transient") else { return }

        rig.fakeA.setStatusSilently(.invalid)
        rig.manager.startActivation(of: rig.b)
        guard check(rig.a.status == .deactivating,
                    "the occupant is held on the reading that cannot answer — status=\(rig.a.status)") else { return }
        guard check(rig.a.isHoldingForAnAnswer,
                    "with a backstop standing behind that hold") else { return }

        rig.fakeA.drive(.reasserting)
        _ = await settle(within: 0.5) { rig.a.status != .deactivating }
        check(rig.a.status == .deactivating,
              "a .reasserting says the session is still WORKING, not that the stop is done, so it does not repaint"
              + " the held row out from under its backstop — status=\(rig.a.status)")

        rig.fakeA.drive(.connecting)
        _ = await settle(within: 0.5) { rig.a.status != .deactivating }
        check(rig.a.status == .deactivating,
              "and neither does a .connecting, the other reading that would have painted a live-looking status onto"
              + " a row that is being held — status=\(rig.a.status)")

        guard check(rig.a.isHoldingForAnAnswer,
                    "the backstop is still standing and has not spent its budget, so what hands the queue on below"
                    + " is the ANSWER rather than the ceiling running out under a slow rig") else { return }

        rig.fakeA.drive(.disconnected)
        let tookItsTurn = await settle(within: 3) { rig.fakeB.startCount >= 1 }
        check(tookItsTurn,
              "only the TERMINAL answer hands the queue on — starts=\(rig.fakeB.startCount), expected 1")
        guard check(rig.a.status == .inactive,
                    "with the occupant grounded on it — status=\(rig.a.status)") else { return }

        rig.fakeA.drive(.reasserting)
        let repainted = await settle(within: 1) { rig.a.status == .reasserting }
        check(repainted,
              "and that SAME reading repaints the row once no backstop stands behind it — which is what says the"
              + " two above were barred rather than never delivered (status=\(rig.a.status))")
    }

    func aLateInvalidDoesNotHandOnTheQueueEither() async {
        guard let rig = invalidQueueRig("LateInvalid") else { return }

        rig.manager.startActivation(of: rig.b)
        guard check(rig.a.status == .deactivating,
                    "the occupant's stop landed through the ordinary door, with the system still reading .connected"
                    + " when it was asked — status=\(rig.a.status)") else { return }
        guard check(!rig.a.isHoldingForAnAnswer,
                    "so NO ceiling was armed on the way out — this is the door a real session takes and the one the"
                    + " synchronous arm never sees") else { return }
        guard check(rig.b.status == .waiting && rig.fakeB.startCount == 0,
                    "with the slot held for the queued tunnel and nothing raised yet") else { return }

        rig.fakeA.drive(.invalid)
        let startedOnTheReading = await settle(within: 1) { rig.fakeB.startCount > 0 }
        check(!startedOnTheReading,
              "an .invalid that arrives AFTER the stop still cannot tell a finished session from a live one, so it"
              + " does not hand the slot on — starts=\(rig.fakeB.startCount), expected 0")
        check(rig.a.status == .deactivating,
              "and the row is HELD rather than grounded on that reading — status=\(rig.a.status)")
        guard check(rig.a.isHoldingForAnAnswer,
                    "the notification armed the hold itself, which is both the fix and the proof that the reading"
                    + " reached the handler rather than never arriving") else { return }

        rig.fakeA.drive(.disconnected)
        let tookItsTurn = await settle(within: 3) { rig.fakeB.startCount >= 1 }
        check(tookItsTurn,
              "and the system's OWN answer hands the queue on — starts=\(rig.fakeB.startCount), expected 1")
        check(rig.a.status == .inactive,
              "with the occupant grounded on that answer rather than on the reading that could not give one —"
              + " status=\(rig.a.status)")
    }

    func anInvalidWhileTheStopWaitsOnItsRuleHoldsToo() async {
        guard let rig = invalidQueueRig("StopWaiting") else { return }
        rig.fakeA.arrangeArmed()
        guard rig.a.isActivateOnDemandEnabled else {
            fail("the rig's occupant is not armed, so its stop would not park on a disarm at all")
            return
        }
        rig.fakeA.saveAnswer = .succeedsAfter(seconds: TunnelsManager.groundingBudget + 2)

        rig.manager.startActivation(of: rig.b)
        let disarmIssued = await settle(within: 3) { rig.fakeA.saveCount == 1 }
        guard check(disarmIssued,
                    "the armed occupant's stop parked on its own disarm save — saves=\(rig.fakeA.saveCount)")
        else { return }
        guard check(rig.a.status == .active,
                    "and while that save is in flight the row is still ACTIVE, because performDeactivation runs"
                    + " INSIDE the parked task — status=\(rig.a.status)") else { return }
        guard check(rig.a.stopIsWaitingOnItsRule,
                    "which is the window the row itself already names, rather than a second notion of stopping")
        else { return }
        guard check(!rig.a.isHoldingForAnAnswer && rig.fakeB.startCount == 0,
                    "with no ceiling behind it yet and nothing raised") else { return }

        rig.fakeA.drive(.invalid)
        let startedOnTheReading = await settle(within: 1) { rig.fakeB.startCount > 0 }
        check(!startedOnTheReading,
              "an .invalid arriving in THAT window does not hand the slot on over a session still reading up —"
              + " starts=\(rig.fakeB.startCount), expected 0")
        check(rig.a.status == .deactivating,
              "the row is taken into the hold instead of grounded — status=\(rig.a.status)")
        guard check(!rig.a.isHoldingForAnAnswer,
                    "and NO ceiling is armed yet: the stop is still inside the parked disarm, so a budget started"
                    + " here would be counting down a wait that has not begun") else { return }

        let spentTheBudget = await settle(within: TunnelsManager.groundingBudget + 1) { rig.fakeB.startCount > 0 }
        check(!spentTheBudget,
              "a whole budget passes with the stop still parked and nothing grounded on it — starts="
              + "\(rig.fakeB.startCount), status=\(rig.a.status)")

        let stopWentOut = await settle(within: 4) { rig.fakeA.stopCount >= 1 }
        guard check(stopWentOut,
                    "the parked disarm then finished and put the stop out — stops=\(rig.fakeA.stopCount)")
        else { return }
        check(rig.a.isHoldingForAnAnswer,
              "and THAT is when the ceiling is armed, so the budget it spends measures the wait for an answer to a"
              + " stop that has actually been issued")

        rig.fakeA.drive(.disconnected)
        let tookItsTurn = await settle(within: 3) { rig.fakeB.startCount >= 1 }
        check(tookItsTurn,
              "only the terminal answer hands the queue on — starts=\(rig.fakeB.startCount), expected 1")
        check(rig.a.status == .inactive,
              "with the occupant grounded on that answer — status=\(rig.a.status)")
    }

    func aTerminalReadingEndsTheHoldWhereverItIsRead() async {
        guard let rig = invalidQueueRig("HoldRelease") else { return }

        rig.fakeA.setStatusSilently(.invalid)
        rig.manager.startActivation(of: rig.b)
        guard check(rig.a.status == .deactivating && rig.a.isHoldingForAnAnswer,
                    "the occupant is held with a backstop behind it — status=\(rig.a.status)") else { return }

        rig.fakeA.setStatusSilently(.reasserting)
        rig.a.refreshStatus()
        check(rig.a.status == .deactivating,
              "a list refresh that reads a transient leaves the hold exactly where it was — status=\(rig.a.status)")
        guard check(rig.a.isHoldingForAnAnswer,
                    "backstop included, which is what makes the SAME call below a measurement of the reading rather"
                    + " than of the call") else { return }

        rig.fakeA.setStatusSilently(.disconnected)
        rig.a.refreshStatus()
        check(rig.a.status == .inactive,
              "the same call reading a TERMINAL answer repaints the row — status=\(rig.a.status)")
        check(!rig.a.isHoldingForAnAnswer,
              "and takes the hold down with it, so no ceiling outlives the row it was holding and turns up later to"
              + " suppress a reading in some other flow")
    }

    func aTeardownTakesTheCeilingsItFinds() async {
        guard let rig = invalidQueueRig("CeilingSweep") else { return }

        rig.fakeA.setStatusSilently(.invalid)
        rig.manager.startActivation(of: rig.b)
        guard check(rig.a.isHoldingForAnAnswer,
                    "a ceiling stands before the teardown begins, which is what the sweep below has to find")
        else { return }

        rig.manager.suspendRefreshForUninstall()
        await rig.manager.disarmAllRecovery()
        guard check(rig.manager.isStoreHeldForTeardown,
                    "the teardown holds the store") else { return }
        check(!rig.a.isHoldingForAnAnswer,
              "and its sweep took the standing ceiling with every other deferred task, rather than leaving one"
              + " behind to fire after the store is given back")
        check(rig.a.status == .inactive,
              "and it finished what that ceiling would have done rather than leaving the row stopping for ever —"
              + " a row left at deactivating holds the single slot against every tunnel including itself"
              + " (status=\(rig.a.status))")
    }

    func aHoldThatMayNotArmStillRefusesToGround() async {
        guard let rig = invalidQueueRig("NoArmNoGround") else { return }

        rig.manager.suspendRefreshForUninstall()
        guard check(rig.manager.isStoreHeldForTeardown,
                    "a teardown holds the store before the stop below is even issued") else { return }

        rig.manager.startActivation(of: rig.b)
        guard check(rig.a.status == .deactivating && !rig.a.isHoldingForAnAnswer,
                    "so the occupant's stop lands with no ceiling behind it, and none may be armed while the store"
                    + " is held — status=\(rig.a.status)") else { return }

        rig.fakeA.drive(.invalid)
        _ = await settle(within: 1) { rig.a.status != .deactivating }
        check(!rig.a.isHoldingForAnAnswer,
              "the reading arms nothing, because arming is a write and the store is not ours right now")
        check(rig.a.status == .deactivating,
              "but it does not GROUND the row either — a reading that may not be acted on is still not an answer,"
              + " and refusing to arm is no licence to decide (status=\(rig.a.status))")
        check(rig.fakeB.startCount == 0,
              "so nothing was handed the slot on the strength of it — starts=\(rig.fakeB.startCount), expected 0")
    }
}
#endif
