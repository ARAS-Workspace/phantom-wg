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
