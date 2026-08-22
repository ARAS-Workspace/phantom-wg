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
// Activation Seam — The Hand-Off And The Teardown's Store
//
// Steps belonging to `ActivationSeamWorkflow`; the registry lives in the
// main file. One subject: handing the slot to a queued tunnel is a WRITE
// to the system store, so it answers to the same latch every other writer
// answers to.
//
// `reload()` asks whether a teardown holds the store before it reconciles
// and again before it hands on. The hand-off itself was not asking, so a
// status notification arriving mid-uninstall could start a queued tunnel —
// arming its recovery rule — while the flow above it was taking entries
// and extensions down.
//
// Scenario:
//
//   A — A Teardown Holding The Store Takes No Hand-Off
//       The bar, carrying its own control: the same notification is driven
//       twice, once with the store held and once with it given back. The
//       second half is what says the first half measured a bar rather than
//       a rig that could not take a turn at all.
//
// The reading is deliberately taken off `waitingTunnel` and the rows' own
// statuses rather than off `startCount`: those move synchronously inside
// the handler, so nothing here waits on the real vault that the rung-0
// pre-flight reads.
//
// What this file does not prove is the same bar against the OTHER caller
// that can reach the hand-off mid-uninstall — a grounding ceiling whose
// budget expires inside `removableEntryIds()`. Staging that needs a slow
// vault and a wall clock; the bar it would meet is the one proven here, on
// the door that needs no timer.

#if DEBUG
import Foundation
import NetworkExtension

extension ActivationSeamWorkflow {

    func aTeardownHoldingTheStoreTakesNoHandOff() async {
        guard let rig = invalidQueueRig("HandOffBar") else { return }

        rig.manager.startActivation(of: rig.b)
        guard check(rig.b.status == .waiting,
                    "the slot is held for the queued tunnel — status=\(rig.b.status)") else { return }
        guard check(rig.a.status == .deactivating,
                    "and the occupant took the ordinary door: its stop landed while the system still read"
                    + " .connected — status=\(rig.a.status)") else { return }
        guard check(!rig.a.isHoldingForAnAnswer,
                    "so no ceiling stands behind it, which is what makes the notification below a plain one"
                    + " rather than the held-occupant case another step already covers") else { return }

        rig.manager.suspendRefreshForUninstall()
        guard check(rig.manager.isStoreHeldForTeardown,
                    "a teardown now holds the store, which is the whole arrangement") else { return }

        rig.fakeA.drive(.disconnected)
        let grounded = await settle(within: 3) { rig.a.status == .inactive }
        guard check(grounded,
                    "the notification reached the handler and grounded the row it names, so the hand-off one"
                    + " line behind it has already run or already been barred — the readings below wait on"
                    + " nothing") else { return }

        check(rig.manager.waitingTunnel === rig.b,
              "and it was barred: the slot is still the queued tunnel's, not spent while a teardown holds the"
              + " store")
        check(rig.b.status == .waiting,
              "with the queued row left where the teardown will find it — status=\(rig.b.status)")

        rig.manager.releaseStoreAfterUninstall()
        guard check(!rig.manager.isStoreHeldForTeardown,
                    "the store is given back") else { return }

        rig.fakeA.drive(.disconnected)
        let handedOn = await settle(within: 3) { rig.b.status == .activating }
        check(handedOn,
              "and the SAME reading hands the slot on once the store is back — which is what says the bar"
              + " above was the teardown's and not this rig's inability to take a turn (status="
              + "\(rig.b.status))")
        check(rig.manager.waitingTunnel == nil,
              "with the slot given up as it went")
    }
}
#endif
