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
// Activation Seam — The Mirror Steps
//
// Steps belonging to `ActivationSeamWorkflow`; the registry lives in the
// main file. The principle they stand on: what NE says is shown and
// not remembered; the app knows only what the user asked for; the field's
// real ordering rules stay; uncertainty is said to the user, in a sentence.
//
// Every step here is written against BEHAVIOR the user can see - row
// states, start/stop counts, sentences - never against machinery. Each one
// began life as a designed-red step against the ceiling-and-hold machine
// this family used to carry; what they measure now is the mirror those
// reds demanded.

#if DEBUG
import Foundation
import NetworkExtension

extension ActivationSeamWorkflow {

    // The armed branch waits on the disarm save only to the user's
    // patience: a save the system never answers does not park the stop,
    // and what could not be confirmed is said.
    func aStopTheRuleSaveCannotAnswerStillGoesOut() async {
        guard let rig = invalidQueueRig("Patience") else { return }
        rig.fakeA.arrangeArmed()
        guard rig.a.isActivateOnDemandEnabled else {
            fail("the rig's occupant is not armed, so its stop would not wait on a disarm at all")
            return
        }
        rig.fakeA.saveAnswer = .hangs
        onTeardown("patience rig's held save") { [weak self] in
            let released = rig.fakeA.releaseHeldCompletions()
            self?.log("teardown: released \(released) held save(s) from the patience rig")
        }

        rig.manager.startDeactivation(of: rig.a)
        guard check(rig.a.pendingDisarmCount == 1 && rig.fakeA.stopCount == 0,
                    "the disarm goes out first and the stop waits on it — count=\(rig.a.pendingDisarmCount),"
                    + " stops=\(rig.fakeA.stopCount)") else { return }

        let stopped = await settle(within: 5) { rig.fakeA.stopCount >= 1 }
        check(stopped,
              "a disarm save the system never answers does not park the stop past the user's patience —"
              + " the stop still goes out within a few seconds (stops=\(rig.fakeA.stopCount), expected 1)")
        var said = false
        if case .stopRuleStandDownUnconfirmed = rig.a.lastActivationError { said = true }
        check(said,
              "and the function ends with a sentence: the rule's stand-down could not be confirmed,"
              + " which is the one thing the user cannot see on their own —"
              + " error=\(rig.a.lastActivationError.map { String(describing: $0) } ?? "nil")")

        rig.fakeA.saveAnswer = .succeeds
        _ = rig.fakeA.releaseHeldCompletions()
        let drained = await settle(within: 3) { rig.a.pendingDisarmCount == 0 }
        check(drained,
              "and the counted park had already ended at the patience — the released save"
              + " lands without feeding the count — count=\(rig.a.pendingDisarmCount)")
    }

    // Fighting the rule is a loop, so a session it brings back after our
    // stop keeps the one stop it got: the risen session is shown, and why
    // it is still up is said. The verdict reads the LIVE connection — no
    // repaint is driven before it, so the sentence must land while the row
    // still wears the stop's own paint.
    func aSessionTheRuleBringsBackIsShownNotFought() async {
        guard let rig = invalidQueueRig("Fought") else { return }
        guard check(!rig.a.isActivateOnDemandEnabled,
                    "the occupant is UNARMED, so its stop runs inline and the rule repair follows it") else { return }

        rig.manager.startDeactivation(of: rig.a)
        guard check(rig.fakeA.stopCount == 1,
                    "the stop goes out once, inline — stops=\(rig.fakeA.stopCount)") else { return }
        check(rig.a.status == .deactivating,
              "and the row wears the stop's paint while the system still holds the session — status=\(rig.a.status)")

        let said = await settle(within: 4) {
            if case .connectedDespiteStopRequest = rig.a.lastActivationError { return true }
            return false
        }
        check(said,
              "and what happened is SAID from the live reading, under that paint: connected despite the stop"
              + " request, the reconnect rule may still be registered —"
              + " error=\(rig.a.lastActivationError.map { String(describing: $0) } ?? "nil")")

        rig.fakeA.drive(.connected)
        let mirrored = await settle(within: 2) { rig.a.status == .active }
        check(mirrored,
              "the rule's session is then shown when its notification arrives — status=\(rig.a.status)")
        var kept = false
        if case .connectedDespiteStopRequest = rig.a.lastActivationError { kept = true }
        check(kept, "with the sentence surviving the rise it predicted")
        check(rig.fakeA.stopCount == 1,
              "the session the rule brought back is NOT stopped again — the sentence above proves the"
              + " repair has finished, and the one stop still stands (stops=\(rig.fakeA.stopCount), expected 1)")
    }

    // The slot question is asked of the live reading: .invalid is not
    // occupancy, so a press on B starts B, asks nothing of the occupant,
    // and repaints nobody.
    func anUnknownOccupantDoesNotBarTheQueue() async {
        guard let rig = invalidQueueRig("Unknown") else { return }
        check(!rig.a.isActivateOnDemandEnabled,
              "the occupant is unarmed, so nothing here waits on a rule")

        rig.fakeA.setStatusSilently(.invalid)
        rig.manager.startActivation(of: rig.b)

        check(rig.b.status != .waiting,
              "a session the system already calls .invalid does not occupy the slot — B is not queued"
              + " behind it (b=\(rig.b.status))")
        check(rig.fakeA.stopCount == 0,
              "and no stop is issued to it — the user never asked that row for anything"
              + " (stops=\(rig.fakeA.stopCount))")
        check(rig.a.status != .deactivating,
              "and the row is not repainted as stopping on nobody's behalf — it shows what is known"
              + " (a=\(rig.a.status))")

        let started = await settle(within: 8) { rig.fakeB.startCount >= 1 }
        check(started,
              "and B's start actually reaches the system — starts=\(rig.fakeB.startCount), expected 1")
    }

    // An attempt the system drops ends where it ended: no start the user
    // never asked for goes out, and the drop is explained in a sentence.
    func aDropEndsWithASentenceNotASecondStart() async {
        guard let rig = await activatedRig(name: "TE-Seam-Drop-\(runTag)",
                                           retryInterval: 1.0, maxRetries: 2, configure: { _ in }) else { return }
        guard check(rig.container.status == .activating,
                    "the attempt is mid-flight when the system drops it — status=\(rig.container.status)")
        else { return }
        let startsBeforeDrop = rig.fake.startCount

        rig.fake.drive(.disconnected)

        let errored = await settle(within: 5) { rig.container.lastActivationError != nil }
        check(errored,
              "the drop ends with a sentence the user can read — not a silent second try"
              + " (error=\(String(describing: rig.container.lastActivationError)))")
        // Derived negative window, the wedged/dying pattern: the reading
        // outlasts the rig's own retry interval by construction.
        let window = rig.manager.preflightBudget + rig.manager.retryInterval
        _ = await settle(within: window) { rig.fake.startCount > startsBeforeDrop }
        check(rig.fake.startCount == startsBeforeDrop,
              "and no start the user never asked for goes out — starts=\(rig.fake.startCount),"
              + " expected \(startsBeforeDrop)")
    }

    // The withdrawal ceiling is the attempt's own backstop, and it must
    // reach a row whose reading went .unknown mid-attempt: that is one of
    // the very "never resolved" endings it exists for. A guard still written
    // for the old folding would skip the withdrawal, leave the attempt flag
    // up, and the flag alone pins the slot against every tunnel.
    func anAttemptWedgedOverAnUnknownReadingIsStillWithdrawn() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-UnknownWedge-\(runTag)", createdAt: Date(), isGhost: false)
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
            fail("side manager did not materialize the unknown-wedge tunnel")
            return
        }
        onTeardown("unknown-wedge save") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: nothing was still held — the unknown-wedge step released its own wedge"
                      : "teardown: released \(released) held request(s) from the unknown-wedge rig")
        }

        manager.startActivation(of: container)
        guard await settle(within: 8, until: { fake.saveCount >= 1 }) else {
            skip("environment: the rung never reached its arm save")
            return
        }
        guard check(container.status == .activating,
                    "the attempt is wedged inside a save that will never answer — status=\(container.status)")
        else { return }

        fake.setStatusSilently(.invalid)

        let explained = await settle(within: 8) { container.lastActivationError != nil }
        check(explained,
              "the ceiling withdraws an attempt whose reading went .unknown mid-flight — that ending is"
              + " exactly what it exists for (error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil"))")
        var named = false
        if case .activationUnresolved = container.lastActivationError { named = true }
        check(named, "and says the system never answered rather than inventing an error it did not give")
        check(!container.isAttemptingActivation,
              "the attempt flag comes down with it — the flag alone occupies the slot, so a withdrawal"
              + " this guard skips would pin the queue against every tunnel")
        check(container.status == .unknown,
              "and the row shows what is known — status=\(container.status)")

        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
    }

    // GUARD (green on both sides of the rework) - the frequent case the
    // live-reading gate must not sacrifice: a user who turns A off and
    // immediately presses B gets an ORDERLY hand-over. While A's stop is
    // still landing (.disconnecting inside the stop-landing window), B
    // queues; the window is a timestamp, closed by arithmetic.
    func aSecondPressQueuesBehindAStopStillLanding() async {
        guard let rig = invalidQueueRig("QueueOrder") else { return }
        check(!rig.a.isActivateOnDemandEnabled,
              "the occupant is unarmed, so its stop goes out inline on the press")

        rig.manager.startDeactivation(of: rig.a)
        guard check(rig.fakeA.stopCount == 1,
                    "the stop is out — stops=\(rig.fakeA.stopCount)") else { return }
        rig.fakeA.setStatusSilently(.disconnecting)

        rig.manager.startActivation(of: rig.b)
        check(rig.b.status == .waiting,
              "a second press while that stop is still landing takes the queue rather than racing the"
              + " session down — b=\(rig.b.status)")
        check(rig.fakeB.startCount == 0,
              "so no session is raised over one the system is still taking down (starts=\(rig.fakeB.startCount))")

        rig.fakeA.drive(.disconnected)
        let served = await settle(within: 5) { rig.fakeB.startCount >= 1 }
        check(served,
              "and the terminal answer serves the queue in order — starts=\(rig.fakeB.startCount), expected 1")
    }

    // The stamp window's other half: the step above proves the window
    // HOLDS the queue while it is open; this one proves it CLOSES — by
    // arithmetic alone, because a stop the system never finishes posts no
    // notification to close it with.
    func aStopTheSystemNeverFinishesCannotPinTheQueue() async {
        guard let rig = invalidQueueRig("NeverLands") else { return }
        check(!rig.a.isActivateOnDemandEnabled,
              "the occupant is unarmed, so its stop goes out inline on the press")

        rig.manager.startDeactivation(of: rig.a)
        guard check(rig.fakeA.stopCount == 1,
                    "the stop is out — stops=\(rig.fakeA.stopCount)") else { return }
        guard let issued = rig.a.stopIssuedAt else {
            fail("the stop left no stamp, so there is no window to measure")
            return
        }
        rig.fakeA.setStatusSilently(.disconnecting)

        rig.manager.startActivation(of: rig.b)
        guard check(rig.b.status == .waiting,
                    "a second press queues B behind the stop still landing — status=\(rig.b.status)")
        else { return }

        // KONTROL, ahead of the bar's own reading and inside the window:
        // the same gate that must hand the queue on later refuses now.
        guard check(ContinuousClock.now - issued < .seconds(TunnelsManager.disarmPatience),
                    "the stop-landing window is provably still open as the gate below is pressed")
        else { return }
        rig.manager.activateWaitingTunnelIfNeeded()
        check(rig.manager.waitingTunnel === rig.b && rig.b.status == .waiting,
              "and a hand-off gate pressed inside the window leaves the slot queued — the .disconnecting"
              + " occupant still holds it (status=\(rig.b.status))")
        check(rig.fakeB.startCount == 0,
              "with no session raised over the stop still landing (starts=\(rig.fakeB.startCount))")

        // The subject here IS the arithmetic closing, and no notification
        // will ever come — so a timer is the one honest way to spend the
        // window: the stamp's own patience, with the margin on top.
        try? await Task.sleep(for: .seconds(TunnelsManager.disarmPatience + 0.5))

        rig.manager.activateWaitingTunnelIfNeeded()
        let served = await settle(within: 12) { rig.fakeB.startCount >= 1 }
        check(served,
              "past the stamp's patience the SAME gate hands the queue on — a stop the system never"
              + " finishes cannot pin it (starts=\(rig.fakeB.startCount), expected 1)")
        rig.manager.startDeactivation(of: rig.b)
    }

    // Queueing is a fresh user request: the old sentence comes down at the
    // .waiting paint, the same clearing rung 0 does. A queued row wearing
    // last attempt's failure would tell the user the NEW press already
    // failed. The vault is driven, so both verdicts here are arrangements.
    func aPressThatQueuesShedsTheOldSentence() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-ShedA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-ShedB-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .disconnected)
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .disconnected)
        fakeB.startAnswer = .fails(NSError(domain: "TE.Seam", code: 53,
                                           userInfo: [NSLocalizedDescriptionKey: "driven start refusal"]))
        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([]))
        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let b = manager.tunnels.first(where: { $0.id == idB.id }) else {
            fail("side manager did not materialize the shed-sentence rig")
            return
        }

        manager.startActivation(of: b)
        let refused = await settle(within: 8) {
            if case .startingFailed = b.lastActivationError { return true }
            return false
        }
        guard check(refused,
                    "the first press earned a real sentence — the system refused its start"
                    + " (error=\(b.lastActivationError.map { String(describing: $0) } ?? "nil"))") else { return }
        guard check(b.status == .inactive, "and the row grounded under it — status=\(b.status)") else { return }

        fakeB.startAnswer = .succeeds
        fakeA.setStatusSilently(.connected)
        manager.startActivation(of: b)
        guard check(b.status == .waiting,
                    "the second press queued behind the now-live occupant — status=\(b.status)") else { return }
        check(fakeA.stopCount == 1,
              "and the press's stop reached that occupant under its stale paint — the shed is a real stop,"
              + " not a slot the paint happened to leave open (stops=\(fakeA.stopCount))")
        check(b.lastActivationError == nil,
              "and the queue paint sheds the old sentence: this press is a fresh request, and rung 0 would"
              + " have cleared the sentence had the slot been free — error="
              + "\(b.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(fakeB.startCount == 1,
              "while no second start has gone out — the slot is genuinely occupied (starts=\(fakeB.startCount))")

        manager.startDeactivation(of: b)
        check(b.status == .inactive, "hygiene: the withdrawn slot grounds on its provable rest — status=\(b.status)")
    }

    // The stop's entry gate asks BOTH surfaces, because its callers do
    // not: a silent paint sitting over a session whose rise notification
    // is still queued cannot swallow the queue press's stop. The twin
    // window is unchanged — when neither surface implies a session, the
    // gate still returns and no second stop goes out.
    func aQueuePressStillStopsAStalePaintedOccupant() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-StaleStopA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-StaleStopB-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .disconnected)
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
            fail("side manager did not materialize the stale-stop rig")
            return
        }

        // TWIN first, on the same rig: live .disconnecting under a silent
        // paint — neither surface implies a session, so the gate returns
        // and the stop-landing window draws no second stop.
        fakeA.setStatusSilently(.disconnecting)
        manager.startDeactivation(of: a)
        guard check(fakeA.stopCount == 0,
                    "a silent paint over a live .disconnecting draws no stop from the gate — the"
                    + " second-stop window is unchanged (stops=\(fakeA.stopCount))") else { return }

        // The stale paint under test: live .connected while the paint
        // still reads .inactive — the rise notification never delivered.
        fakeA.setStatusSilently(.connected)
        manager.startActivation(of: b)
        guard check(b.status == .waiting,
                    "the press queued B behind the stale-painted occupant — status=\(b.status)") else { return }
        check(fakeA.stopCount == 1,
              "and the press's stop REACHED that occupant: the gate read the live session under the silent"
              + " paint instead of swallowing the stop (stops=\(fakeA.stopCount))")
        check(a.status == .deactivating,
              "with the row handed to the stop it now carries — status=\(a.status)")

        // The sentence walks its own path: A's descent hands B the slot.
        fakeA.drive(.disconnected)
        let served = await settle(within: 12) { fakeB.startCount >= 1 }
        check(served,
              "and A's descent hands the queue on — B's start reaches the system"
              + " (starts=\(fakeB.startCount), expected 1)")
    }
}
#endif
