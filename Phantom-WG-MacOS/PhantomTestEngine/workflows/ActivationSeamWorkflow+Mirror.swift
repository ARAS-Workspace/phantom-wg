#if DEBUG
import Foundation
import NetworkExtension

// The mirror steps. The principle they stand on: what NE says is shown and
// not remembered; the app knows only what the user asked for; the field's
// real ordering rules stay; uncertainty is said to the user, in a sentence.
//
// Every step here is written against BEHAVIOR the user can see - row
// states, start/stop counts, sentences - never against machinery. Each one
// began life as a designed-red step against the ceiling-and-hold machine
// this family used to carry; what they measure now is the mirror those
// reds demanded.
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
              "and the parked disarm drains inside this step once its save is answered —"
              + " count=\(rig.a.pendingDisarmCount)")
    }

    // Fighting the rule is a loop, so a session it brings back after our
    // stop keeps the one stop it got: the risen session is shown, and why
    // it is still up is said.
    func aSessionTheRuleBringsBackIsShownNotFought() async {
        guard let rig = invalidQueueRig("Fought") else { return }
        guard check(!rig.a.isActivateOnDemandEnabled,
                    "the occupant is UNARMED, so its stop runs inline and the rule repair follows it") else { return }
        rig.fakeA.saveAnswer = .succeedsAfter(seconds: 1)

        rig.manager.startDeactivation(of: rig.a)
        guard check(rig.fakeA.stopCount == 1,
                    "the stop goes out once, inline — stops=\(rig.fakeA.stopCount)") else { return }

        rig.fakeA.drive(.connected)
        let mirrored = await settle(within: 2) { rig.a.status == .active }
        guard check(mirrored,
                    "the rule brings the session back and the row mirrors it — status=\(rig.a.status)") else { return }

        let said = await settle(within: 4) {
            if case .connectedDespiteStopRequest = rig.a.lastActivationError { return true }
            return false
        }
        check(said,
              "and what happened is SAID: connected despite the stop request, the reconnect rule may"
              + " still be registered — error=\(rig.a.lastActivationError.map { String(describing: $0) } ?? "nil")")
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
        guard let rig = await activatedRig(name: "TE-Seam-Drop-\(runTag)", configure: { _ in }) else { return }
        guard check(rig.container.status == .activating,
                    "the attempt is mid-flight when the system drops it — status=\(rig.container.status)")
        else { return }
        let startsBeforeDrop = rig.fake.startCount

        rig.fake.drive(.disconnected)

        let errored = await settle(within: 5) { rig.container.lastActivationError != nil }
        check(errored,
              "the drop ends with a sentence the user can read — not a silent second try"
              + " (error=\(String(describing: rig.container.lastActivationError)))")
        check(rig.fake.startCount == startsBeforeDrop,
              "and no start the user never asked for goes out — starts=\(rig.fake.startCount),"
              + " expected \(startsBeforeDrop)")
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
}
#endif
