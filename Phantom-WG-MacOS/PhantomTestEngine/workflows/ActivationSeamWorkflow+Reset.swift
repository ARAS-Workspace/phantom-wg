#if DEBUG
import Foundation

// Opcode 3's reply, driven against a fake that can answer in shapes a
// deployed extension cannot — an older extension's bare byte, a newer
// one's unknown byte, and no answer at all. Split off at a type
// boundary, the same way the rule-ownership family was: the rigs, the
// polling helper and the run tag belong to `ActivationSeamWorkflow`
// itself, and this is the same workflow, continued.
//
// What it cannot prove is the other side of the wire. The extension's
// four endings and the bytes it really writes are witnessed against
// the DEPLOYED extension, in `PhantomTunnelWorkflow`.
extension ActivationSeamWorkflow {

    /// The window the interface could not see, now that it can.
    ///
    /// A stop on an ARMED row waits for the recovery rule's save
    /// before anything moves: the status stays `.active`, the toggle
    /// stays ON, and if the save hangs that is the whole experience.
    /// The count is what the row reads to say otherwise, so what has
    /// to be proven is that it is UP during the wait and back DOWN
    /// after — on the ordinary exit and on the refused one, which are
    /// the two that reach the end of the task body by different
    /// routes.
    ///
    /// Read as a count, not as a flag, and driven that way: the second
    /// tap is the documented escape from a wedged stop and it puts a
    /// second disarm in flight beside the first, so a flag would come
    /// down on whichever finished first and the row would go quiet
    /// with a save still outstanding.
    func stopOnAnArmedRowIsVisibleWhileItWaits() async {
        guard let rig = await drivenActiveRig("TE-Seam-StopSeen-\(runTag)") else { return }
        guard rig.fake.storedOnDemand else {
            skip("environment: the rig's activation did not leave a rule armed, so the armed stop branch is not the one under test")
            return
        }
        // Held open on purpose: without a slow save there is no window
        // to observe, and a step that measured an instant one would
        // pass against a row that never showed anything.
        rig.fake.saveAnswer = .succeedsAfter(seconds: 2)
        rig.manager.startDeactivation(of: rig.container)

        let rose = await settle(within: 2, until: { rig.container.pendingDisarmCount > 0 })
        check(rose, "the row can say a stop is under way before the status moves — count=\(rig.container.pendingDisarmCount)")
        check(rig.container.status == .active,
              "and it says it while the status still reads active, which is the whole reason it exists — status=\(rig.container.status)")
        // A second stop dispatched in the SAME main-actor turn, before
        // the first disarm task has had a chance to run. Both are
        // counted, which a flag could not do.
        //
        // Deliberately not called the second tap of a wedged stop —
        // it is not that path, and saying so was a defect of its own.
        // `settle` returns before its first sleep when the condition
        // already holds, and `check` does not suspend, so nothing
        // between the two calls yields the main actor: the first
        // task's body has not started, the provider flag is still
        // armed, and this second call takes the ARMED branch. A real
        // second tap arrives after that flag is down and takes the
        // other one — which is the step below.
        rig.manager.startDeactivation(of: rig.container)
        check(rig.container.pendingDisarmCount == 2,
              "two stops dispatched in one turn are both counted rather than one replacing the other (count=\(rig.container.pendingDisarmCount))")

        let cleared = await settle(within: 12, until: { rig.container.pendingDisarmCount == 0 })
        check(cleared, "and both came down when their saves answered — count=\(rig.container.pendingDisarmCount)")
        check(rig.container.status == .inactive || rig.container.status == .deactivating,
              "with the stop itself landing past them — status=\(rig.container.status)")

        // The refused exit reaches the end of the same task body by a
        // different route: it writes a verdict first. A count left
        // standing there would leave the row claiming to be stopping
        // for the life of the process.
        guard let refused = await drivenActiveRig("TE-Seam-StopRefused-\(runTag)") else { return }
        refused.fake.saveAnswer = .fails(NSError(domain: "TE.Seam", code: 48,
                                                 userInfo: [NSLocalizedDescriptionKey: "driven disarm refusal"]))
        refused.manager.startDeactivation(of: refused.container)
        let refusedCleared = await settle(within: 8, until: { refused.container.pendingDisarmCount == 0 })
        check(refusedCleared,
              "a refused disarm lowers the count too, rather than leaving the row stopping forever — count=\(refused.container.pendingDisarmCount)")
        var surfaced = false
        if case .savingFailed = refused.container.lastActivationError { surfaced = true }
        check(surfaced,
              "and the refusal still surfaced, so the count came down past a verdict rather than instead of one — \(refused.container.lastActivationError.map { String(describing: $0) } ?? "nil")")
    }

    /// The bug the count shipped with, and the reading that closes it.
    ///
    /// A hint gated on `pendingDisarmCount` alone outlives its own
    /// stop. The count comes down when the disarm SAVE answers, but
    /// `standDownRecovery` writes the provider flag down before it
    /// awaits that save — so a second stop during a hung save reads
    /// the row as already disarmed, takes the branch that deactivates
    /// immediately, and grounds it. The count is still up, and the
    /// row read "stopping" under an Inactive status with its toggle
    /// off, for as long as the save stayed out.
    ///
    /// This drives the REAL second tap: it waits for the flag to go
    /// down before pressing again, which is the whole difference
    /// between this step and the one above.
    func aLandedStopStopsClaimingToBeUnderWay() async {
        guard let rig = await drivenActiveRig("TE-Seam-StopHint-\(runTag)") else { return }
        guard rig.fake.storedOnDemand else {
            skip("environment: the rig's activation left no armed rule, so the armed stop branch is not the one under test")
            return
        }
        // Never answers. This is the wedged stop the hint exists for,
        // and the only shape in which the count can outlive its stop.
        rig.fake.saveAnswer = .hangs
        onTeardown("stop-hint rig's held save") { [weak self] in
            let released = rig.fake.releaseHeldCompletions()
            self?.log("teardown: released \(released) held save(s) from the stop-hint rig")
        }

        rig.manager.startDeactivation(of: rig.container)
        guard await settle(within: 3, until: { rig.container.pendingDisarmCount > 0 }) else {
            fail("the armed stop never registered a pending disarm — count=\(rig.container.pendingDisarmCount)")
            return
        }
        check(rig.container.stopIsWaitingOnItsRule,
              "the row says a stop is under way while its own status still shows nothing — status=\(rig.container.status)")

        // The task has started and written the flag down, which is
        // what sends the next stop through the other branch. Read on
        // the FAKE's own flag rather than on a sleep, so the step
        // presses when the state is real rather than when a guess
        // says it should be.
        guard await settle(within: 3, until: { !rig.fake.isOnDemandEnabled }) else {
            skip("environment: the disarm never reached its save, so the second stop would take the same branch as the first")
            return
        }
        rig.manager.startDeactivation(of: rig.container)
        guard await settle(within: 5, until: {
            rig.container.status == .inactive || rig.container.status == .deactivating
        }) else {
            fail("the second stop did not land — status=\(rig.container.status)")
            return
        }
        // Both readings together are the finding: a count that is
        // still up, over a row that has already stopped.
        check(rig.container.pendingDisarmCount > 0,
              "the first disarm is still parked on a save nobody will answer, which is what makes the reading below worth taking (count=\(rig.container.pendingDisarmCount))")
        check(!rig.container.stopIsWaitingOnItsRule,
              "and the row stopped claiming a stop was under way once the stop actually landed — status=\(rig.container.status), count=\(rig.container.pendingDisarmCount)")
    }

    /// Brings a rig's row to `.active`, which is the only state the
    /// reset path will act on. Separated so the two steps below share
    /// one arrangement and neither of them re-states it.
    func drivenActiveRig(
        _ name: String
    ) async -> (fake: FakeSlotProvider, manager: TunnelsManager, container: TunnelContainer)? {
        guard let rig = await activatedRig(name: name, configure: { _ in }) else { return nil }
        rig.fake.drive(.connected)
        guard await settle(within: 3, until: { rig.container.status == .active }) else {
            fail("the driven session never reached the handler — status=\(rig.container.status)")
            return nil
        }
        return rig
    }

    /// The app's half of the outcome byte. The extension has always
    /// had four ways for a reset to end, and until the byte existed
    /// all four reached this caller as the same nothing — so the
    /// wrapper returned cleanly over a layer that was down, and the
    /// user's Reset button reported success for it.
    ///
    /// Four answers driven through the real wrapper, including the
    /// one no deployed extension can send any more: a bare `[3]` must
    /// still mean what it has always meant, because reading an older
    /// extension's silence as a failure would invent one.
    func resetOutcomeByteDecidesTheVerdict() async {
        guard let rig = await drivenActiveRig("TE-Seam-ResetByte-\(runTag)") else { return }
        let verdict: (FakeSlotProvider.ResetAnswer) async -> Error? = { answer in
            rig.fake.resetAnswer = answer
            do {
                try await rig.manager.resetConnection(of: rig.container)
                return nil
            } catch {
                return error
            }
        }

        let rebuilt = await verdict(.status(.rebuilt))
        check(rebuilt == nil,
              "a layer that came back answers with no error — \(rebuilt?.localizedDescription ?? "no error")")
        check(rig.fake.providerMessageCount == 1,
              "and the reset was actually issued rather than refused at the status guard (messages=\(rig.fake.providerMessageCount))")

        let down = await verdict(.status(.adapterFailed))
        var layerDown = false
        if case TunnelManagementError.resetLayerDown? = down { layerDown = true }
        check(layerDown,
              "an adapter that never restarted reaches the user as a layer that is down — \(down?.localizedDescription ?? "NO ERROR")")

        let nothing = await verdict(.status(.skipped))
        var nothingToRebuild = false
        if case TunnelManagementError.resetNothingToRebuild? = nothing { nothingToRebuild = true }
        check(nothingToRebuild,
              "and an extension with no layer to rebuild says so rather than passing for success — \(nothing?.localizedDescription ?? "NO ERROR")")

        let legacy = await verdict(.legacy)
        check(legacy == nil,
              "while a reply with no outcome byte still means what it meant before the byte existed — \(legacy?.localizedDescription ?? "no error")")
        // The other direction of the same compatibility question: a
        // NEWER extension answering a byte this app has no case for.
        // Read as unknown rather than as a failure, deliberately and
        // for the same reason — the app cannot conclude a failure it
        // was never told about, and inventing one here would be the
        // exact mistake the legacy arm above avoids.
        let unknown = await verdict(.rawStatus(200))
        check(unknown == nil,
              "and an outcome byte from a newer extension is not read as a failure this app was never told about — \(unknown?.localizedDescription ?? "no error")")
        check(rig.fake.providerMessageCount == 5,
              "all five verdicts came from a message that was really sent (messages=\(rig.fake.providerMessageCount), expected 5)")
    }

    /// The ceiling, and the only way to see it: an extension that
    /// takes the message and never calls back. Before the ceiling
    /// existed this step could not have been written — the wrapper
    /// would have suspended here for the life of the process, with
    /// the user's Reset button awaiting it and no error ever reaching
    /// the alert.
    func resetNobodyAnswersEndsItsOwnWait() async {
        guard let rig = await drivenActiveRig("TE-Seam-ResetMute-\(runTag)") else { return }
        rig.fake.resetAnswer = .silent

        let start = Date()
        var thrown: Error?
        do { try await rig.manager.resetConnection(of: rig.container) } catch { thrown = error }
        let elapsed = Date().timeIntervalSince(start)

        var unanswered = false
        if case TunnelManagementError.resetUnanswered? = thrown { unanswered = true }
        check(unanswered,
              "the wait ended on its own budget, with the silence named — \(thrown?.localizedDescription ?? "NO ERROR")")
        // The message really was handed over: what follows is a
        // ceiling ending a wait, not a send that never happened.
        check(rig.fake.providerMessageCount == 1,
              "and the message had been handed to the session before anything gave up (messages=\(rig.fake.providerMessageCount))")
        // Bounded from BOTH sides. Without the lower bound this check
        // would pass just as well against a wrapper that gave up
        // instantly, which is a different product and a worse one.
        check(elapsed >= 8 && elapsed < 20,
              "and it spent its budget rather than giving up early or hanging — took \(String(format: "%.1f", elapsed))s")
        // Nothing was concluded about the layer. An extension that
        // never answered may still have rebuilt, and the row here is
        // the one the user is looking at.
        check(rig.container.status == .active,
              "the row was left where the system has it, since a silence is not a verdict about the session — status=\(rig.container.status)")
    }
}
#endif
