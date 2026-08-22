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
// Activation Seam — The Teardown's Store And The Writers Under It
//
// Steps belonging to `ActivationSeamWorkflow`; the registry lives in the
// main file. One invariant: while a teardown holds the store, nothing may
// raise a session or arm a recovery rule under it. `reload()` already
// asked; the writers below were not.
//
// The invariant has two doors, and each earns its own step because each
// was open for a different reason.
//
// Scenarios:
//
//   A — A Teardown Holding The Store Takes No Hand-Off
//       The queue hand-off is a write, so a status notification arriving
//       mid-uninstall could start a queued tunnel while the flow above was
//       taking entries and extensions down. The step carries its own
//       control: the same notification is driven twice, once with the
//       store held and once with it given back, so the first half is
//       measuring a bar rather than a rig that could not take a turn.
//
//   B — A Teardown Holding The Store Arms Nothing
//       The hand-off is only one caller. `armRecovery` has a single call
//       site, inside the rung task that `startActivation(of:at:)` spawns,
//       and every door — the user's own press, a respawn revive, the retry
//       ladder, the hand-off — funnels through it. This step drives the
//       ladder, which climbs on its own against a fake nothing answers, and
//       proves the bar where all four doors meet. Its control comes FIRST:
//       the climb is measured before the store is taken.
//
// Neither reading is taken off a timer where one can be avoided. A's
// readings move synchronously inside the notification handler; B's are
// snapshotted the moment a rung lands, so the next rung is a whole
// interval away rather than in flight across the bar.
//
// What this file does not prove is the ceiling door — a grounding ceiling
// whose budget expires inside `removableEntryIds()`. Staging that needs a
// slow vault and a wall clock; the bars it would meet are the two proven
// here.

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

    func aTeardownHoldingTheStoreArmsNothing() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-ArmBar-\(runTag)",
                                      createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            retryInterval: 0.6,
            maxRetries: 12,
            observesSystemChanges: false
        )
        guard let row = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the ladder rig")
            return
        }

        manager.startActivation(of: row)
        let climbed = await settle(within: 6) { fake.saveCount >= 2 }
        guard check(climbed,
                    "the ladder climbs on its own: nothing ever answers this session, so the row stays activating"
                    + " and every rung arms the rule again — saves=\(fake.saveCount)") else { return }
        guard check(fake.storedOnDemand,
                    "and the arm each rung writes really LANDS in the store, which is the thing a teardown must"
                    + " not have written under it") else { return }

        let landed = fake.saveCount
        let anotherLanded = await settle(within: 3) { fake.saveCount > landed }
        guard check(anotherLanded,
                    "a rung has landed this very moment, which is what puts the next one a whole interval away"
                    + " rather than in flight across the bar below — saves=\(fake.saveCount)") else { return }

        manager.suspendRefreshForUninstall()
        guard check(manager.isStoreHeldForTeardown,
                    "and now a teardown holds the store") else { return }

        let savesAtBar = fake.saveCount
        let startsAtBar = fake.startCount
        _ = await settle(within: 2) { fake.saveCount > savesAtBar }
        check(fake.saveCount == savesAtBar,
              "the ladder armed nothing more while the teardown held the store — saves=\(fake.saveCount),"
              + " unchanged from \(savesAtBar)")
        check(fake.startCount == startsAtBar,
              "nor raised another session under it — starts=\(fake.startCount), unchanged from \(startsAtBar)")
        check(savesAtBar < 12,
              "with rungs left to climb, so what ended the climb is the teardown rather than a ladder that ran"
              + " out — \(savesAtBar) of the twelve it was given had been spent")
    }
}
#endif
