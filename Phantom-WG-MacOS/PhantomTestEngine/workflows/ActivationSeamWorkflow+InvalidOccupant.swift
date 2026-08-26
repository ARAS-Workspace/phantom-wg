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
// Activation Seam — The Two-Row Queue Rig
//
// Steps belonging to `ActivationSeamWorkflow`; the registry lives in the
// main file. This file holds the shared two-row rig — a live-looking
// occupant A and a queued B on a side manager — and the teardown contract
// measured on it. The `.invalid` occupant's own story lives in `+Mirror`:
// what NE says is shown, not remembered, and the slot question is asked of
// the live reading rather than of any painted status.

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

    // The sweep awaits every activation rung and the one deferred task that
    // can repaint a row `.deactivating`: the parked disarm. With the wait on
    // that disarm bounded to the user's patience, the park cannot outlive the
    // sweep's own budget — but the sweep still WAITS rather than stepping
    // over a stop in flight, which is the ordering contract measured here.
    func aTeardownWaitsOutTheStopItParked() async {
        guard let rig = invalidQueueRig("SweepWaits") else { return }
        rig.fakeA.arrangeArmed()
        guard rig.a.isActivateOnDemandEnabled else {
            fail("the rig's occupant is not armed, so its stop would not park on a disarm at all")
            return
        }
        rig.fakeA.saveAnswer = .succeedsAfter(seconds: 2)
        rig.fakeA.setStatusSilently(.invalid)

        rig.manager.startDeactivation(of: rig.a)
        guard await settle(within: 3, until: { rig.fakeA.saveCount == 1 }) else {
            fail("the parked disarm never reached its save, so nothing here is arranged to be slow —"
                 + " saves=\(rig.fakeA.saveCount)")
            return
        }
        guard check(rig.a.pendingDisarmCount == 1 && rig.fakeA.stopCount == 0,
                    "the stop is parked on its own disarm save and has not gone out — count="
                    + "\(rig.a.pendingDisarmCount), stops=\(rig.fakeA.stopCount)") else { return }
        // Only now: the slow save is already ISSUED, so restoring the answer
        // cannot reach it. Set before the disarm task's body ever ran, this
        // whole arrangement would be inert and the guard below would hold
        // against the unfixed sweep too.
        rig.fakeA.saveAnswer = .succeeds

        rig.manager.suspendRefreshForUninstall()
        await rig.manager.disarmAllRecovery()

        guard check(rig.fakeA.stopCount == 1,
                    "the sweep waited that stop out instead of stepping over it — every OTHER save in this rig"
                    + " answers at once, so the only thing it could have been waiting on is the parked disarm"
                    + " (stops=\(rig.fakeA.stopCount))") else { return }
        check(rig.a.status == .inactive,
              "with the row that stop repainted carried to a verdict rather than left stopping for ever —"
              + " status=\(rig.a.status)")
    }
}
#endif
