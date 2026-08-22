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
}
#endif
