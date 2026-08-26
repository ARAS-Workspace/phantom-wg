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
// Activation Seam — Stop Visibility and Opcode 3
//
// Steps belonging to `ActivationSeamWorkflow`; the registry lives in the
// main file. Two subjects share this file:
//
//   The armed stop's own visibility while it waits. A stop on an ARMED row
//   waits for the recovery rule's save up to the user's patience — the
//   status stays `.active` and the row says a stand-down is under way. A
//   save that never answers cannot make that the whole experience any
//   more: the stop still goes out, the hint ends by arithmetic, and what
//   it can no longer show is said in a sentence. These steps drive that
//   window and read what the interface sees on both sides of it.
//
//   Opcode 3's reply, driven against a fake that can answer in shapes a
//   deployed extension cannot: an older extension's bare byte, a newer
//   one's unknown byte, and no answer at all.
//
// What this file cannot prove is the other side of the wire. The bytes the
// extension really writes are witnessed against the DEPLOYED extension in
// `PhantomTunnelWorkflow`, and only for the one ending a live session can
// produce — the failure endings no run can arrange stay unwitnessed there
// by construction.

#if DEBUG
import Foundation

extension ActivationSeamWorkflow {

    func stopOnAnArmedRowIsVisibleWhileItWaits() async {
        guard let rig = await drivenActiveRig("TE-Seam-StopSeen-\(runTag)") else { return }
        guard rig.fake.storedOnDemand else {
            skip("environment: the rig's activation did not leave a rule armed, so the armed stop branch is not the one under test")
            return
        }
        rig.fake.saveAnswer = .succeedsAfter(seconds: 2)
        rig.manager.startDeactivation(of: rig.container)

        let rose = await settle(within: 2, until: { rig.container.pendingDisarmCount > 0 })
        check(rose, "the row can say a stop is under way before the status moves — count=\(rig.container.pendingDisarmCount)")
        check(rig.container.status == .active,
              "and it says it while the status still reads active, which is the whole reason it exists — status=\(rig.container.status)")
        rig.manager.startDeactivation(of: rig.container)
        check(rig.container.pendingDisarmCount == 2,
              "two stops dispatched in one turn are both counted rather than one replacing the other (count=\(rig.container.pendingDisarmCount))")

        let cleared = await settle(within: 12, until: { rig.container.pendingDisarmCount == 0 })
        check(cleared, "and both came down when their saves answered — count=\(rig.container.pendingDisarmCount)")
        check(rig.container.status == .inactive || rig.container.status == .deactivating,
              "with the stop itself landing past them — status=\(rig.container.status)")

        guard let refused = await drivenActiveRig("TE-Seam-StopRefused-\(runTag)") else { return }
        refused.fake.saveAnswer = .fails(NSError(domain: "TE.Seam", code: 48,
                                                 userInfo: [NSLocalizedDescriptionKey: "driven disarm refusal"]))
        refused.manager.startDeactivation(of: refused.container)
        let refusedCleared = await settle(within: 8, until: { refused.container.pendingDisarmCount == 0 })
        check(refusedCleared,
              "a refused disarm lowers the count too, rather than leaving the row stopping forever — count=\(refused.container.pendingDisarmCount)")
        var surfaced = false
        if case .stopDisarmRefused = refused.container.lastActivationError { surfaced = true }
        check(surfaced,
              "and the refusal still surfaced, so the count came down past a verdict rather than instead of one — \(refused.container.lastActivationError.map { String(describing: $0) } ?? "nil")")
    }

    func theStopHintOutlivesTheStopAndEndsWithASentence() async {
        guard let rig = await drivenActiveRig("TE-Seam-StopHint-\(runTag)") else { return }
        guard rig.fake.storedOnDemand else {
            skip("environment: the rig's activation left no armed rule, so the armed stop branch is not the one under test")
            return
        }
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
              "the row says a rule stand-down is under way while its own status still shows nothing — status=\(rig.container.status)")

        guard await settle(within: 3, until: { !rig.fake.isOnDemandEnabled }) else {
            skip("environment: the disarm never cleared its flag, so the second press would take the same branch as the first")
            return
        }
        rig.manager.startDeactivation(of: rig.container)
        guard await settle(within: 5, until: {
            rig.container.status == .inactive || rig.container.status == .deactivating
        }) else {
            fail("the second stop did not land — status=\(rig.container.status)")
            return
        }
        check(rig.container.stopIsWaitingOnItsRule,
              "and the hint OUTLIVES that landed stop, because the first disarm save is still in flight —"
              + " the claim is about the rule, not the session (count=\(rig.container.pendingDisarmCount))")

        let hintEnded = await settle(within: TunnelsManager.disarmPatience + 2) {
            rig.container.pendingDisarmCount == 0
        }
        check(hintEnded,
              "the hint ends with the patience, by arithmetic — nothing had to remember to take it down"
              + " (count=\(rig.container.pendingDisarmCount))")
        var said = false
        if case .stopRuleStandDownUnconfirmed = rig.container.lastActivationError { said = true }
        check(said,
              "and what the hint can no longer show is now SAID: the rule's stand-down was not confirmed —"
              + " error=\(rig.container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(rig.fake.stopCount == 2,
              "with each press having put its own stop out rather than parking behind the save —"
              + " stops=\(rig.fake.stopCount)")
        _ = rig.fake.releaseHeldCompletions()
    }

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
        let unknown = await verdict(.rawStatus(200))
        var unreadable = false
        if case TunnelManagementError.resetOutcomeUnrecognised(let raw)? = unknown { unreadable = raw == 200 }
        check(unreadable,
              "and an outcome byte from a newer extension reaches the user as an answer that could not be read, carrying the byte itself — \(unknown?.localizedDescription ?? "NO ERROR")")
        check(rig.fake.providerMessageCount == 5,
              "all five verdicts came from a message that was really sent (messages=\(rig.fake.providerMessageCount), expected 5)")
    }

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
        check(rig.fake.providerMessageCount == 1,
              "and the message had been handed to the session before anything gave up (messages=\(rig.fake.providerMessageCount))")
        check(elapsed >= 8 && elapsed < 20,
              "and it spent its budget rather than giving up early or hanging — took \(String(format: "%.1f", elapsed))s")
        check(rig.container.status == .active,
              "the row was left where the system has it, since a silence is not a verdict about the session — status=\(rig.container.status)")
    }
}
#endif
