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
//       Its windows are read back off the rig rather than written as
//       literals, so retuning the rig cannot quietly turn a bar reading
//       vacuous. The ladder is given far more rungs than it climbs for two
//       reasons: exhaustion is excluded by measurement, and each rung's
//       withdrawal watchdog sleeps `(maxRetries + 1) * retryInterval +
//       preflightBudget`, which must stay well past the step's own end or
//       its stand-down save would be read as an arm.
//
//   C — A Rung Already Past The Entry Arms Nothing Either
//       B bars the DOOR; this bars the WRITE. A rung-0 body suspends in
//       its slot pre-flight before it arms, and on the way out it used to
//       re-read only the attempt and the row — never the store's latch. A
//       vault that answers late parks that pre-flight for exactly the
//       budget `bounded` allows, so the teardown can be staged inside it.
//       The pre-flight is single-shot per manager, so the control cannot
//       follow the bar on one rig: it runs FIRST, on a twin.
//
//   D — A Row The List Dropped Raises No Session Either
//       C bars the ARM; this bars the START. Two awaits still sit between
//       the arm and `startTunnel` — the arm's own save and the load behind
//       it — and only one guard is needed to cover both, because it sits
//       past them. The step also drives the OTHER way a row stops being
//       this manager's: not a teardown and not a removal, but an ingest
//       that rebuilds the list without it. That door leaves `removingIds`
//       empty and the latch down, so it is the LIST alone the guard must
//       notice — which is why `mayArmRecovery` had to become a strict
//       subset of `mayWriteStore` rather than a second opinion beside it.
//       Both halves are barred in one step because each needs the other:
//       the latch half fails without the guard, the dropped half fails
//       without the subset.
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
            maxRetries: 30,
            observesSystemChanges: false
        )
        guard let row = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the ladder rig")
            return
        }

        let aRungOrTwo = manager.preflightBudget + manager.retryInterval * 4
        manager.startActivation(of: row)
        let climbed = await settle(within: aRungOrTwo) { fake.saveCount >= 2 }
        guard check(climbed,
                    "the ladder climbs on its own: nothing ever answers this session, so the row stays activating"
                    + " and every rung arms the rule again — saves=\(fake.saveCount)") else { return }
        guard check(fake.storedOnDemand,
                    "and the arm each rung writes really LANDS in the store, which is the thing a teardown must"
                    + " not have written under it") else { return }

        let landed = fake.saveCount
        let anotherLanded = await settle(within: aRungOrTwo) { fake.saveCount > landed }
        guard check(anotherLanded,
                    "a rung has landed this very moment, which is what puts the next one a whole interval away"
                    + " rather than in flight across the bar below — saves=\(fake.saveCount)") else { return }

        manager.suspendRefreshForUninstall()
        guard check(manager.isStoreHeldForTeardown,
                    "and now a teardown holds the store") else { return }

        let savesAtBar = fake.saveCount
        let startsAtBar = fake.startCount
        let attemptAtBar = row.activationAttemptId
        let threeIntervals = manager.retryInterval * 3
        _ = await settle(within: threeIntervals) { fake.saveCount > savesAtBar }
        check(fake.saveCount == savesAtBar,
              "the ladder armed nothing more across three of its own intervals while the teardown held the store"
              + " — saves=\(fake.saveCount), unchanged from \(savesAtBar)")
        check(fake.startCount == startsAtBar,
              "nor raised another session under it — starts=\(fake.startCount), unchanged from \(startsAtBar)")
        check(row.activationAttemptId == attemptAtBar,
              "and the rung was turned back at the ENTRY rather than deeper in: no new attempt was minted for it,"
              + " which is the one reading the write-site bar further down cannot produce")
        check(savesAtBar < manager.maxRetries,
              "with rungs left to climb, so what ended the climb is the teardown rather than a ladder that ran"
              + " out — \(savesAtBar) of the \(manager.maxRetries) it was given had been spent")
    }

    private func parkedPreflightRig(_ label: String) -> (
        fake: FakeSlotProvider, row: TunnelContainer, manager: TunnelsManager
    )? {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-\(label)-\(runTag)",
                                      createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answersAfter(seconds: 30, .unreachable)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: faultVault,
            retryInterval: 30,
            observesSystemChanges: false
        )
        guard let row = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the parked pre-flight rig")
            return nil
        }
        return (fake, row, manager)
    }

    func aRungAlreadyPastTheEntryArmsNothingEither() async {
        guard let control = parkedPreflightRig("InFlightFree") else { return }
        let parked = control.manager.preflightBudget

        control.manager.startActivation(of: control.row)
        guard check(control.fake.saveCount == 0,
                    "the rung is past the entry guard and inside its rung-0 pre-flight, where nothing has been"
                    + " written yet — saves=\(control.fake.saveCount)") else { return }
        let controlArmed = await settle(within: parked * 2) { control.fake.storedOnDemand }
        guard check(controlArmed,
                    "and with nobody taking the store it comes out of that pre-flight and ARMS — which is what says"
                    + " a parked rung can reach the write at all (saves=\(control.fake.saveCount),"
                    + " starts=\(control.fake.startCount))") else { return }

        guard let barred = parkedPreflightRig("InFlightHeld") else { return }
        barred.manager.startActivation(of: barred.row)
        _ = await settle(within: parked / 2) { barred.fake.saveCount > 0 }
        guard check(barred.fake.saveCount == 0,
                    "its twin is still inside the same pre-flight half a budget later, so the store below is taken"
                    + " while that rung is genuinely in flight rather than before it began") else { return }

        barred.manager.suspendRefreshForUninstall()
        guard check(barred.manager.isStoreHeldForTeardown,
                    "a teardown takes the store from under a rung that already passed the entry guard") else { return }

        _ = await settle(within: parked * 2) { barred.fake.saveCount > 0 }
        check(!barred.fake.storedOnDemand,
              "so the rung asks again on its way out of the pre-flight and arms nothing — the reading it entered on"
              + " is not the one it acts on (storedOnDemand=\(barred.fake.storedOnDemand))")
        check(barred.fake.saveCount == 0,
              "with no save issued at all — saves=\(barred.fake.saveCount), expected 0")
        check(barred.fake.startCount == 0,
              "and no session raised under the teardown — starts=\(barred.fake.startCount), expected 0")
    }

    private func armedSaveParkRig(_ label: String, dropsOnPrune: Bool) -> (
        fake: FakeSlotProvider, row: TunnelContainer, manager: TunnelsManager
    )? {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-\(label)-\(runTag)",
                                      createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        fake.saveAnswer = .succeedsAfter(seconds: 1)
        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([]))
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: dropsOnPrune ? [] : [fake]),
            vault: faultVault,
            retryInterval: 30,
            observesSystemChanges: false
        )
        guard let row = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the parked-save rig")
            return nil
        }
        return (fake, row, manager)
    }

    func aRowTheListDroppedRaisesNoSessionEither() async {
        guard let control = armedSaveParkRig("SaveParkFree", dropsOnPrune: false) else { return }
        control.manager.startActivation(of: control.row)
        let controlIssued = await settle(within: 4) { control.fake.saveCount == 1 }
        guard check(controlIssued,
                    "the rung armed and its save is in flight — the two awaits between the arm and startTunnel are"
                    + " open (saves=\(control.fake.saveCount))") else { return }
        let controlStarted = await settle(within: 4) { control.fake.startCount > 0 }
        guard check(controlStarted,
                    "and with nothing changing under it the save lands and the session goes up — which is what says"
                    + " a rung parked at its save can reach startTunnel at all (starts=\(control.fake.startCount))")
        else { return }

        guard let held = armedSaveParkRig("SaveParkHeld", dropsOnPrune: false) else { return }
        held.manager.startActivation(of: held.row)
        let heldIssued = await settle(within: 4) { held.fake.saveCount == 1 }
        guard check(heldIssued,
                    "a second rung is parked at the same save") else { return }
        held.manager.suspendRefreshForUninstall()
        guard check(held.manager.isStoreHeldForTeardown,
                    "and a teardown takes the store before that save lands") else { return }
        _ = await settle(within: 4) { held.fake.startCount > 0 }
        check(held.fake.startCount == 0,
              "so the rung asks again past its save and raises no session under the teardown —"
              + " starts=\(held.fake.startCount), expected 0")

        guard let dropped = armedSaveParkRig("SaveParkDropped", dropsOnPrune: true) else { return }
        dropped.manager.startActivation(of: dropped.row)
        let droppedIssued = await settle(within: 4) { dropped.fake.saveCount == 1 }
        guard check(droppedIssued,
                    "a third rung is parked at the same save") else { return }
        await dropped.manager.prune()
        guard check(!dropped.manager.tunnels.contains(where: { $0 === dropped.row }),
                    "and an INGEST rebuilds the list without its row — the door that is neither a teardown nor a"
                    + " removal") else { return }
        guard check(!dropped.manager.isStoreHeldForTeardown && dropped.manager.removingIds.isEmpty,
                    "with the latch down and no removal in flight, so the LIST alone is what the guard below has to"
                    + " notice") else { return }
        _ = await settle(within: 4) { dropped.fake.startCount > 0 }
        check(dropped.fake.startCount == 0,
              "so no session is raised on a provider this manager no longer holds —"
              + " starts=\(dropped.fake.startCount), expected 0")
    }
}
#endif
