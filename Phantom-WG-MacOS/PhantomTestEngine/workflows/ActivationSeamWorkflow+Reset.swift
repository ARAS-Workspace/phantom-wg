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
        // The second tap, which is the documented way out of a wedged
        // stop. Both disarms are in flight now, and a flag would be
        // wrong here in a way a count is not.
        rig.manager.startDeactivation(of: rig.container)
        check(rig.container.pendingDisarmCount == 2,
              "a second stop is counted beside the first rather than replacing it (count=\(rig.container.pendingDisarmCount))")

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
