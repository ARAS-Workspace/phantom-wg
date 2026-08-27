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
// Activation Seam — Rule Ownership
//
// Steps belonging to `ActivationSeamWorkflow`; the registry lives in the
// main file. They drive one question: WHO owns the recovery rule, and what
// a row may wear while the system disagrees with this process about it.
//
// The hard case these steps exist for is a flag that LIES — a disarm save
// that never answered leaves this process believing the rule is down while
// the store still holds it. A row can therefore be grounded and armed at
// the same time, and a sweep that filters on the flag skips precisely the
// rows it was written to clear.
//
// Split off at a type boundary rather than by moving a threshold: the rigs
// and the run tag belong to the main file, the polling helper lives on
// `TestWorkflow`.

#if DEBUG
import Foundation
import NetworkExtension

extension ActivationSeamWorkflow {

    func groundedRowIsStillWithdrawn() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Grounded-\(runTag)", createdAt: Date(), isGhost: false)
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
            fail("side manager did not materialize the grounded-row tunnel")
            return
        }
        onTeardown("grounded-row rig") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: nothing was held, as this rig intends"
                      : "teardown: released \(released) held request(s)")
        }

        manager.startActivation(of: container)
        guard await settle(within: 4, until: { fake.startCount >= 1 }) else {
            skip("environment: the rig's activation never reached startTunnel within the ceiling (vault verdict too slow?)")
            return
        }
        check(fake.storedOnDemand,
              "the rung armed the rule in the STORE, which is what the withdrawal below has to clear")

        fake.drive(.disconnecting)
        guard await settle(within: 3, until: { container.status == .deactivating }) else {
            fail("the driven .disconnecting never painted the row — status=\(container.status)")
            return
        }
        let savesAtArm = fake.saveCount
        check(container.isAttemptingActivation && container.activationAttemptId != nil,
              "the attempt is still owned while the session dies under it")

        fake.setStatusSilently(.disconnected)
        container.refreshStatus()
        check(container.status == .inactive,
              "a refresh grounded the row while its attempt was still live — status=\(container.status)")
        check(container.isAttemptingActivation && container.lastActivationError == nil,
              "and the grounding wrote nothing into the ledger: that is what makes the attempt unresolved rather than finished")

        let explained = await settle(within: 8) { container.lastActivationError != nil }
        check(explained,
              "the ceiling still withdrew the attempt from under a grounded row — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        var named = false
        if case .activationUnresolved = container.lastActivationError { named = true }
        check(named, "and named the silence rather than inventing an error the system never gave")
        check(!container.isAttemptingActivation, "the attempt flag came down with it")

        let disarmed = await settle(within: 3) { !fake.storedOnDemand }
        check(disarmed,
              "the recovery rule came down in the store, not just in the flag (store=\(fake.storedOnDemand), flag=\(fake.isOnDemandEnabled))")
        check(fake.saveCount == savesAtArm + 1,
              "exactly the withdrawal's own stand-down followed the arm save (saves=\(fake.saveCount), expected \(savesAtArm + 1))")
    }

    func sweepReachesAStoreOnlyRule() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-SweepA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-SweepB-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .disconnected)
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .connected)
        fakeB.isEnabled = true
        fakeB.arrangeArmed()
        fakeB.saveAnswer = .hangs
        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let a = manager.tunnels.first(where: { $0.id == idA.id }),
              let b = manager.tunnels.first(where: { $0.id == idB.id }) else {
            fail("side manager did not materialize the sweep rig")
            return
        }
        onTeardown("wedged stop-disarm (sweep rig)") { [weak self] in
            let released = fakeB.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the sweep rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the sweep rig")
        }

        manager.startDeactivation(of: b)
        guard await settle(within: 5, until: { fakeB.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fakeB.saveCount))")
            return
        }
        check(!fakeB.isOnDemandEnabled && fakeB.storedOnDemand,
              "the wedged stop left the flag down over a rule still in the store (flag=\(fakeB.isOnDemandEnabled), store=\(fakeB.storedOnDemand))")
        check(manager.tunnels.contains(where: { $0.id == idB.id }) && !b.isActivateOnDemandEnabled,
              "and the row is still IN THE LIST while reading disarmed — a listed row is exactly what a flag-filtered sweep walked past")

        // The wedged stop is carried to a terminal answer before the sweep is
        // asked anything: the released save LANDS as a refusal — which writes
        // nothing, so the store-only rule survives its own stop's ending —
        // and the ledger row retires, so the sweep below opens its own save
        // rather than joining a dead one.
        let released = fakeB.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
        guard await settle(within: 8, until: { b.pendingDisarmCount == 0 }) else {
            fail("the wedged stop never reached a terminal answer — count=\(b.pendingDisarmCount)")
            return
        }
        let ledgerClear = await TunnelsManager.awaitLingeringDisarmSave(on: fakeB, within: 5)
        check(ledgerClear, "the ledger row retired with its landed save")
        check(!fakeB.isOnDemandEnabled && fakeB.storedOnDemand,
              "and the refusal wrote nothing back — the store still holds the rule the flag denies (flag=\(fakeB.isOnDemandEnabled), store=\(fakeB.storedOnDemand))")

        fakeB.saveAnswer = .succeeds
        let savesBeforeSweep = fakeB.saveCount

        fakeB.drive(.disconnected)
        guard await settle(within: 3, until: { b.status == .inactive }) else {
            fail("the stopped row never grounded, so rung 0 was never reachable — status=\(b.status)")
            return
        }

        manager.startActivation(of: a)
        let swept = await settle(within: 10) { !fakeB.storedOnDemand }
        check(swept,
              "rung 0 stood down a rule its own flag denied (store=\(fakeB.storedOnDemand), flag=\(fakeB.isOnDemandEnabled))")
        check(fakeB.saveCount > savesBeforeSweep,
              "the sweep issued a save for that row at all (saves=\(fakeB.saveCount), before=\(savesBeforeSweep))")
        manager.startDeactivation(of: a)
    }

    func stopReachesAStoreOnlyRule() async {
        guard let rig = sideRow("TE-Seam-StopRule-\(runTag)", status: .connected, configure: {
            $0.isEnabled = true
            $0.arrangeArmed()
            $0.saveAnswer = .hangs
        }) else { return }
        let (fake, container, manager) = rig
        onTeardown("wedged stop-disarm (stop-rule rig)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the stop-rule rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the stop-rule rig")
        }

        manager.startDeactivation(of: container)
        guard await settle(within: 5, until: { fake.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fake.saveCount))")
            return
        }
        check(!fake.isOnDemandEnabled && fake.storedOnDemand,
              "the wedged stop left the flag down over a rule still in the store (flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand))")
        check(fake.connectionStatus == .connected,
              "and the session it was stopping is still up in the system's own reading — live=connected")

        // The first press is carried to a terminal answer before anything
        // else is claimed: the released save LANDS, and the parked stop ends
        // on one of its own closed endings — refused or unconfirmed — rather
        // than on a clock the readings below would have to race.
        var released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
        guard await settle(within: 8, until: { container.pendingDisarmCount == 0 }) else {
            fail("the parked stop never reached a terminal answer — count=\(container.pendingDisarmCount)")
            return
        }
        var firstEnding = false
        switch container.lastActivationError {
        case .stopDisarmRefused, .stopRuleStandDownUnconfirmed: firstEnding = true
        default: firstEnding = false
        }
        check(firstEnding,
              "the press ended on one of its two terminal sentences — error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(fake.stopCount == 1,
              "and put exactly its own stop out on the way (stops=\(fake.stopCount))")
        let ledgerClear = await TunnelsManager.awaitLingeringDisarmSave(on: fake, within: 5)
        check(ledgerClear && !fake.isOnDemandEnabled && fake.storedOnDemand,
              "the ledger row retired with the landed save, and the refusal wrote nothing back —"
              + " the store still holds the rule the flag denies (flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand))")

        // That rule brings the session back; the row shows it.
        fake.drive(.connected)
        guard await settle(within: 3, until: { container.status == .active }) else {
            fail("the risen session never repainted the row — status=\(container.status)")
            return
        }

        fake.saveAnswer = .succeeds
        let savesBefore = fake.saveCount
        let stopsBefore = fake.stopCount
        manager.startDeactivation(of: container)
        check(fake.stopCount == stopsBefore + 1,
              "the second stop went out BEFORE anything awaited a save (stops=\(fake.stopCount))")

        fake.setStatusSilently(.connecting)
        fake.drive(.connecting)
        let cleared = await settle(within: 8) { !fake.storedOnDemand }
        check(cleared,
              "and the repair behind it stood down the rule its own flag denied (store=\(fake.storedOnDemand), flag=\(fake.isOnDemandEnabled))")
        let said = await settle(within: 8) {
            if case .connectedDespiteStopRequest = container.lastActivationError { return true }
            return false
        }
        check(said,
              "and what happened is SAID rather than fought: connected despite the stop request, read from"
              + " the LIVE session — error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(fake.saveCount == savesBefore + 1,
              "exactly the stop's own stand-down followed (saves=\(fake.saveCount), expected \(savesBefore + 1))")
        // Every flow that could still stop has answered — the first press
        // ended above, the repair's verdict just landed, and the repair
        // writes sentences, not stops — so this read follows terminals
        // rather than spending a timed window.
        check(fake.stopCount == stopsBefore + 1,
              "and the session the rule brought back is NOT stopped again — fighting the rule is a loop, so"
              + " the one stop stands (stops=\(fake.stopCount), expected \(stopsBefore + 1))")
        released = fake.releaseHeldCompletions()
        check(released == 0, "no wedge remains planted (released=\(released))")
    }

    func unconfirmedSentenceSurvivesTheRuleRevival() async {
        guard let rig = sideRow("TE-Seam-Unconfirmed-\(runTag)", status: .connected, configure: {
            $0.isEnabled = true
            $0.arrangeArmed()
            $0.saveAnswer = .hangs
        }) else { return }
        let (fake, container, manager) = rig
        onTeardown("wedged stop-disarm (unconfirmed rig)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the unconfirmed rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the unconfirmed rig")
        }

        manager.startDeactivation(of: container)
        guard await settle(within: 5, until: { fake.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fake.saveCount))")
            return
        }
        guard await settle(within: 8, until: { container.pendingDisarmCount == 0 }) else {
            fail("the parked stop never reached its terminal answer — count=\(container.pendingDisarmCount)")
            return
        }
        var saidUnconfirmed = false
        if case .stopRuleStandDownUnconfirmed = container.lastActivationError { saidUnconfirmed = true }
        guard check(saidUnconfirmed,
                    "the positive control holds first: the save nobody answered was named at the user's patience —"
                    + " error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")") else { return }

        fake.drive(.connected)
        guard await settle(within: 3, until: { container.status == .active }) else {
            fail("the revival never repainted the row — status=\(container.status)")
            return
        }
        var kept = false
        if case .stopRuleStandDownUnconfirmed = container.lastActivationError { kept = true }
        check(kept,
              "the rise does not refute the sentence: it is about the RULE's save, not the session — and the rule"
              + " bringing the session back is that sentence's most likely sequel (error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil"))")
        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
    }

    func stopSurvivorSentenceEndsWithItsSession() async {
        guard let rig = sideRow("TE-Seam-Survivor-\(runTag)", status: .connected, configure: {
            $0.isEnabled = true
        }) else { return }
        let (fake, container, manager) = rig
        guard check(!container.isActivateOnDemandEnabled,
                    "the row is UNARMED, so its stop runs inline and the rule repair follows it") else { return }

        manager.startDeactivation(of: container)
        check(fake.stopCount == 1, "the stop went out inline (stops=\(fake.stopCount))")
        let said = await settle(within: 5) {
            if case .connectedDespiteStopRequest = container.lastActivationError { return true }
            return false
        }
        guard check(said,
                    "the positive control holds first: the survivor sentence is written over the live session —"
                    + " error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")") else { return }

        fake.drive(.disconnected)
        let grounded = await settle(within: 3) { container.status == .inactive }
        check(grounded, "the row grounds on the system's own reading — status=\(container.status)")
        let sentenceGone = await settle(within: 3) { container.lastActivationError == nil }
        check(sentenceGone,
              "and the sentence comes down at the same paint: it named a session, and the live reading now proves"
              + " that session no longer exists — error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")

        // D4's other death: the session ends on a live .invalid instead of
        // a .disconnected. Same proof standard as the slot question — a
        // reading the system walked away from carries no session claim.
        guard let dead = sideRow("TE-Seam-SurvivorDead-\(runTag)", status: .connected, configure: {
            $0.isEnabled = true
        }) else { return }
        dead.manager.startDeactivation(of: dead.container)
        check(dead.fake.stopCount == 1,
              "the second rig's stop went out inline too (stops=\(dead.fake.stopCount))")
        let saidOnDead = await settle(within: 5) {
            if case .connectedDespiteStopRequest = dead.container.lastActivationError { return true }
            return false
        }
        guard check(saidOnDead,
                    "its survivor sentence is written over the live session — the dead-reading leg's own"
                    + " positive control") else { return }

        dead.fake.setStatusSilently(.invalid)
        dead.container.refreshStatus()
        check(dead.container.status == .unknown,
              "this session ended by dying instead of grounding, and the row shows what is known —"
              + " status=\(dead.container.status)")
        check(dead.container.lastActivationError == nil,
              "and the survivor sentence ends with its session HERE too: a live .invalid is a reading the"
              + " system has walked away from — no session claim, the same standard the slot question"
              + " reads — error=\(dead.container.lastActivationError.map { String(describing: $0) } ?? "nil")")
    }

    func restGateClosesAcrossOwnedWindows() async {
        // Positive control first: a row at rest opens the one gate every
        // config door reads. Then each owned window is shown to close it.
        guard let solo = sideRow("TE-Seam-RestGate-\(runTag)", status: .disconnected) else { return }
        check(solo.container.isSettledInactive,
              "a row at rest — live disconnected, painted inactive, no attempt, no waiting stop — opens the gate")

        solo.manager.startActivation(of: solo.container)
        guard check(solo.container.isAttemptingActivation && solo.fake.connectionStatus == .disconnected,
                    "an attempt owns the row while the live reading has not moved — the rung-0 pre-start window")
        else { return }
        check(!solo.container.isSettledInactive, "and the gate is closed across it")
        solo.manager.startDeactivation(of: solo.container)
        let reopened = await settle(within: 5) { solo.container.isSettledInactive }
        check(reopened, "withdrawing the intent reopens the gate once the row is back at rest")

        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-RestGateA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-RestGateB-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .connected)
        fakeA.isEnabled = true
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .disconnected)
        let queue = TunnelsManager(
            tunnelProviders: [fakeA, fakeB],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let b = queue.tunnels.first(where: { $0.id == idB.id }) else {
            fail("side manager did not materialize the rest-gate queue rig")
            return
        }
        queue.startActivation(of: b)
        guard check(b.status == .waiting && b.isKnownInactive,
                    "the queued row holds a slot over a live reading that proves no session") else { return }
        check(!b.isSettledInactive,
              "and the gate is closed on the queue's paint — a door opened here would race its own turn")

        guard let unknown = sideRow("TE-Seam-RestGateU-\(runTag)", status: .invalid) else { return }
        unknown.fake.setStatusSilently(.disconnected)
        guard check(unknown.container.status == .unknown && unknown.container.isKnownInactive,
                    "the unknown paint stands over a live reading that proves no session") else { return }
        check(!unknown.container.isSettledInactive,
              "and the gate keeps the conscious closed door on .unknown: the painted row must concur before a"
              + " config door opens")

        guard let waiting = sideRow("TE-Seam-RestGateW-\(runTag)", status: .connected, configure: {
            $0.isEnabled = true
            $0.arrangeArmed()
            $0.saveAnswer = .hangs
        }) else { return }
        waiting.manager.startDeactivation(of: waiting.container)
        guard await settle(within: 5, until: { waiting.fake.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(waiting.fake.saveCount))")
            return
        }
        waiting.fake.setStatusSilently(.disconnected)
        waiting.container.refreshStatus()
        guard check(waiting.container.status == .inactive && waiting.container.pendingDisarmCount == 1,
                    "the row is painted down and provably sessionless while its stop still waits on the rule")
        else { return }
        check(!waiting.container.isSettledInactive,
              "and the gate is closed on it — the COUNTED park is the gate's whole stop axis; the wider"
              + " set of deferred stand-down saves lives on the ledger, and their order against an edit is"
              + " enforced by modify's own ledger wait rather than widened into this gate")
        let released = waiting.fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
        let settled = await settle(within: 8) { waiting.container.pendingDisarmCount == 0 }
        check(settled && waiting.container.isSettledInactive,
              "and the gate opens when the stop's rule is answered — count=\(waiting.container.pendingDisarmCount)")
    }

    func revivalClearsTheVerdict() async {
        let record = NSError(domain: "TE.Seam", code: 45,
                             userInfo: [NSLocalizedDescriptionKey: "driven start failure"])
        guard let rig = await activatedRig(name: "TE-Seam-Revival-\(runTag)", configure: {
            $0.disconnectAnswer = .record(record)
        }) else { return }

        rig.fake.drive(.disconnected)
        guard await settle(within: 10, until: { rig.container.lastActivationError != nil }) else {
            if !rig.manager.tunnels.contains(where: { $0 === rig.container }) {
                skip("environment: a refresh emptied the side manager's list mid-step")
            } else if case .unreachable = await vault.ping() {
                skip("environment: vault unreachable — the belt's verdict leg never answered")
            } else {
                fail("the drop was never explained, so there is no verdict to shed — error=nil")
            }
            return
        }
        check(rig.container.status == .inactive,
              "the row is down and wearing the failure — status=\(rig.container.status)")

        check(!rig.container.isAttemptingActivation,
              "no attempt of ours is in flight, so what follows is the system's own doing")
        rig.fake.drive(.connected)
        let raised = await settle(within: 5) { rig.container.status == .active }
        check(raised, "the session came back up — status=\(rig.container.status)")
        check(rig.container.lastActivationError == nil,
              "and the row shed the older attempt's verdict as it rose — lastActivationError=\(rig.container.lastActivationError.map { String(describing: $0) } ?? "nil")")

        rig.manager.startDeactivation(of: rig.container)
    }

    func giveUpDoesNotGroundALiveSession() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-LiveGiveUp-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        fake.arrangeArmed()
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the live-give-up tunnel")
            return
        }
        onTeardown("live-give-up rig") { [weak self] in
            let was = container.status
            manager.startDeactivation(of: container)
            self?.log(was == .inactive || was == .deactivating
                      ? "teardown: nothing to stand down (status=\(was))"
                      : "teardown: stood the live-give-up rig's row down from \(was)")
        }

        manager.startActivation(of: container)
        fake.setStatusSilently(.connected)

        guard await settle(within: 10, until: { container.status != .activating }) else {
            // A dark vault does not park this rig — it reroutes it: the
            // pre-flight falls to .free at its bound and the rung arms and
            // starts instead of giving up. The skip names which world this
            // run actually saw, off the rig's own counters.
            if fake.startCount > 0 || fake.isEnabled {
                skip("environment: the vault never proved the collision — the pre-flight fell to .free and"
                     + " the rung armed and started instead (starts=\(fake.startCount),"
                     + " isEnabled=\(fake.isEnabled))")
            } else {
                skip("environment: rung 0 never reached its collision verdict (vault too slow?)")
            }
            return
        }
        check(container.status == .active,
              "the give-up took the system's own reading instead of grounding a live session — status=\(container.status)")
        check(container.lastActivationError == nil,
              "and wrote no verdict over it — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(!container.isAttemptingActivation,
              "the attempt itself was withdrawn, which is what opened the gate for that reading")
        check(!fake.isEnabled,
              "and the manager was never enabled against an occupied slot (isEnabled=\(fake.isEnabled))")
        let disarmed = await settle(within: 3) { !fake.storedOnDemand }
        check(disarmed && fake.saveCount == 1,
              "and the rule came down in the store, as it does on every other collision belt (store=\(fake.storedOnDemand), saves=\(fake.saveCount), expected 1)")
    }

    func peekLeavesARisingSessionAlone() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Peek-\(runTag)", createdAt: Date(), isGhost: false)
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
            fail("side manager did not materialize the peek tunnel")
            return
        }
        onTeardown("wedged arm save (peek rig)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the peek rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the peek rig")
        }

        manager.startActivation(of: container)
        guard await settle(within: 8, until: { fake.saveCount >= 1 }) else {
            skip("environment: the rung never reached its arm save")
            return
        }
        let savesAtArm = fake.saveCount
        fake.setStatusSilently(.connecting)
        check(container.status == .activating,
              "the row is still the manager's, wedged inside a save that will never answer — status=\(container.status)")

        let ceilingPassed = await settle(within: manager.activationCeiling + 3) {
            container.lastActivationError != nil
        }
        check(!ceilingPassed,
              "the ceiling wrote no verdict over a session the system says exists — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(container.isAttemptingActivation,
              "and left the attempt where it was rather than withdrawing it")
        check(fake.saveCount == savesAtArm,
              "no stand-down was issued, because the rule belongs to the session still coming up (saves=\(fake.saveCount), expected \(savesAtArm))")

        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
        manager.startDeactivation(of: container)
    }

    func loadFailureStandsTheRuleDown() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-LoadFail-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        fake.loadAnswer = .fails(NSError(domain: "TE.Seam", code: 46,
                                         userInfo: [NSLocalizedDescriptionKey: "driven load refusal"]))
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the load-failure tunnel")
            return
        }

        onTeardown("load-failure rig") { [weak self] in
            manager.startDeactivation(of: container)
            self?.log("teardown: the load-failure rig's intent was withdrawn")
        }

        manager.startActivation(of: container)
        guard await settle(within: 10, until: { container.lastActivationError != nil }) else {
            fail("the load failure was never filed — lastActivationError=nil")
            return
        }
        var named = false
        if case .loadingFailed = container.lastActivationError { named = true }
        check(named,
              "the exit named the configuration rather than inventing a system failure — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(container.status == .inactive, "the row came back to rest — status=\(container.status)")
        check(!container.isAttemptingActivation, "and the attempt came down with it")
        let disarmed = await settle(within: 3) { !fake.storedOnDemand }
        check(disarmed,
              "the recovery rule came down in the store, so the OS has nothing left to relaunch (store=\(fake.storedOnDemand), flag=\(fake.isOnDemandEnabled))")
        check(fake.startCount == 0,
              "and no session was ever raised from a configuration that would not load (starts=\(fake.startCount))")
    }

    func secondRemovalIsASilentNoOp() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-TwiceRemoved-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        fake.removeAnswer = .succeedsAfter(seconds: 3)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the twice-removed tunnel")
            return
        }

        let first = Task { @MainActor in (try? await manager.remove(tunnel: container)) != nil }
        guard await settle(within: 5, until: { manager.removingIds.contains(identity.id) }) else {
            _ = await first.value
            skip("environment: the removal never reached its in-flight window (vault slow?)")
            return
        }
        let second = Task { @MainActor in (try? await manager.remove(tunnel: container)) != nil }
        let secondAnswered = await second.value
        check(secondAnswered,
              "the second removal answered without an error for a deletion that is already happening")
        check(manager.removingIds.contains(identity.id),
              "and it left the bar where it found it — up, because the first removal still owns it")

        let firstAnswered = await first.value
        guard firstAnswered else {
            skip("environment: the removal itself failed (vault dark?) — the latch contract is unproven this run")
            return
        }
        check(fake.removeCount == 1,
              "the system entry was removed exactly once for two presses (removePreferences=\(fake.removeCount))")
        check(!manager.tunnels.contains(where: { $0.id == identity.id }),
              "the tunnel left the list")
        check(!manager.removingIds.contains(identity.id),
              "and the bar came down once, with the removal that owned it")
    }

    func deleteFlowStopCannotOutrunItsRemoval() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-DeleteOrder-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .connected)
        fake.isEnabled = true
        fake.arrangeArmed()
        let slowDisarm = 2.0
        fake.saveAnswer = .succeedsAfter(seconds: slowDisarm)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the delete-order tunnel")
            return
        }

        manager.startDeactivation(of: container)
        guard await settle(within: 3, until: { fake.saveCount >= 1 }) else {
            fail("the armed stop never issued its disarm save (saves=\(fake.saveCount))")
            return
        }
        fake.saveAnswer = .succeeds
        guard let disarmIssuedAt = fake.lastSaveIssuedAt else {
            fail("the armed stop's disarm was counted but never stamped — the wait cannot be measured from an honest origin")
            return
        }
        let removed = await Task { @MainActor in (try? await manager.remove(tunnel: container)) != nil }.value
        let removalTook = Date().timeIntervalSince(disarmIssuedAt)
        guard removed else {
            skip("environment: the removal failed (vault dark?) — the ordering contract is unproven this run")
            return
        }
        check(removalTook >= slowDisarm,
              "the removal waited the stop's disarm out before it finished (took \(String(format: "%.1f", removalTook))s from the save's own issue, the disarm needed \(String(format: "%.1f", slowDisarm))s)")
        check(!manager.tunnels.contains(where: { $0.id == identity.id }), "the tunnel left the list")
        check(fake.removeCount == 1, "the entry was removed exactly once (removePreferences=\(fake.removeCount))")
        check(fake.saveCount == 2,
              "two saves belong to this flow — the stop's disarm and the removal's own stand-down (saves=\(fake.saveCount), expected 2)")

        let reminted = await settle(within: slowDisarm + 3) { fake.entryExists }
        check(!reminted,
              "and no save landed after the entry went — the removal waited the stop's disarm out instead of racing it (entryExists=\(fake.entryExists))")
    }

    // K-Delete's other half, at the manager's own level: the confirmed
    // Delete carries its stop UNCONDITIONALLY, so the gate itself must be
    // safe on a row with no session on either surface — silent, no stop,
    // no sentence — and the removal behind it still walks. The view's
    // press cannot be driven from here; this is the composite it runs.
    func aDeleteOnARestingRowStopsNothingAndStillRemoves() async {
        guard let rig = sideRow("TE-Seam-RestingDelete-\(runTag)", status: .disconnected) else { return }
        let (fake, container, manager) = rig
        guard check(container.status == .inactive,
                    "the row starts at rest on both surfaces — status=\(container.status)") else { return }

        manager.startDeactivation(of: container)
        check(fake.stopCount == 0,
              "the unconditional stop is swallowed by the gate itself — no stop reaches a session that"
              + " does not exist (stops=\(fake.stopCount))")
        check(container.lastActivationError == nil && container.status == .inactive,
              "with no sentence and no repaint left behind — status=\(container.status)")

        guard let removed = await race(30, { (try? await manager.remove(tunnel: container)) != nil }),
              removed else {
            skip("environment: the removal itself failed (vault dark?) — the composite is unproven this run")
            return
        }
        check(fake.removeCount == 1,
              "and the removal behind the silent gate still walks (removes=\(fake.removeCount))")
        check(!manager.tunnels.contains(where: { $0 === container }), "the tunnel left the list")
    }

    func startFailureStandsTheRuleDown() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-StartFail-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        fake.startAnswer = .fails(NSError(domain: "TE.Seam", code: 47,
                                          userInfo: [NSLocalizedDescriptionKey: "driven start refusal"]))
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the start-failure tunnel")
            return
        }

        onTeardown("start-failure rig") { [weak self] in
            manager.startDeactivation(of: container)
            self?.log("teardown: the start-failure rig's intent was withdrawn")
        }

        manager.startActivation(of: container)
        guard await settle(within: 12, until: { container.lastActivationError != nil }) else {
            fail("the start refusal was never filed — lastActivationError=nil")
            return
        }
        var named = false
        if case .startingFailed = container.lastActivationError { named = true }
        check(named,
              "the system's own refusal was filed rather than a stand-in — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(container.status == .inactive, "the row came back to rest — status=\(container.status)")
        check(fake.startCount == 1,
              "the start was attempted exactly once — a local refusal is not a retry (starts=\(fake.startCount))")
        let disarmed = await settle(within: 3) { !fake.storedOnDemand }
        check(disarmed,
              "and the rule came down in the store, so the OS cannot relaunch a start the system refuses (store=\(fake.storedOnDemand))")
    }

    func theArmedRuleIsOneConnectRuleForAnyInterface() async {
        guard let (fake, _, _) = await activatedRig(
            name: "TE-Seam-RuleBody-\(runTag)",
            configure: { _ in }
        ) else { return }

        check(fake.isOnDemandEnabled && fake.storedOnDemand,
              "the rung armed the rule and the save landed — flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand)")

        let rules = fake.onDemandRules ?? []
        guard check(rules.count == 1,
                    "exactly one rule was written — rules=\(rules.count), expected 1 (the system evaluates the array in order, so a second entry decides ahead of this one)") else {
            return
        }
        guard let connect = rules[0] as? NEOnDemandRuleConnect else {
            fail("the armed rule is a \(type(of: rules[0])) rather than a connect rule — the array that carries it can just as well carry one that keeps the tunnel down")
            return
        }
        check(connect.interfaceTypeMatch == .any,
              "and it is not narrowed to one interface type, so the recovery covers the network the user actually comes back on "
              + "— interfaceTypeMatch=\(connect.interfaceTypeMatch.rawValue), which is also the framework's default: this reading "
              + "catches a narrowing, not a missing assignment")
    }
}
#endif
