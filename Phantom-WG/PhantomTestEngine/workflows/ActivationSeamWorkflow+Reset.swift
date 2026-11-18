// Activation Seam: The Reset (Opcode 3)
//
// `TunnelsManager.resetConnection` driven against a fake that answers in
// shapes a deployed extension cannot: an older extension's bare byte, a
// newer one's unknown byte, a send the session refuses, and no answer at
// all. Mac's ActivationSeam reset steps are the source (T and U); V and W
// are iOS's own.
//
// What this file cannot prove is the other side of the wire: the bytes
// the extension really writes belong to a live family on a device.
//
// Scenarios:
//
//   T — A Reset's Outcome Byte Decides The Caller's Verdict
//       On an active row: rebuilt returns without an error; adapterFailed
//       and wstunnelFailed are the layer-down error; skipped is "nothing
//       to rebuild"; a reply without an outcome byte returns without an
//       error; an unknown byte is named with its value. All six come from
//       a message that was really sent.
//
//   U — A Reset Nobody Answers Ends Its Own Wait
//       The fake never answers: the wait ends on the 10 s budget with the
//       silence named, after the message was sent, and the row is left
//       active.
//
//   V — A Reset The Session Refuses To Send Is Named
//       `sendProviderMessage` throws: the reset fails as a refused send
//       carrying the system's description.
//
//   W — A Reset On A Resting Row Sends Nothing
//       On an inactive row the reset returns without an error and no
//       message is sent.

#if DEBUG
import Foundation
import NetworkExtension

extension ActivationSeamWorkflow {

    private func resetVerdict(_ manager: TunnelsManager, _ row: TunnelContainer) async -> Error? {
        do {
            try await manager.resetConnection(of: row)
            return nil
        } catch {
            return error
        }
    }

    func aResetsOutcomeByteDecidesTheCallersVerdict() async {
        guard let rig = rig("ResetByte", [.connected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])
        guard check(row.status == .active, "the rig's row opens active (status=\(row.status))") else { return }
        func verdict(_ answer: FakeSlotProvider.ResetAnswer) async -> Error? {
            fake.resetAnswer = answer
            return await resetVerdict(manager, row)
        }

        let rebuilt = await verdict(.status(.rebuilt))
        check(rebuilt == nil, "a layer that came back answers with no error (\(rebuilt?.localizedDescription ?? "no error"))")
        let adapter = await verdict(.status(.adapterFailed))
        var adapterDown = false
        if case TunnelManagementError.resetLayerDown? = adapter { adapterDown = true }
        check(adapterDown, "an adapter that did not restart is the layer-down error (\(adapter?.localizedDescription ?? "no error"))")
        let wstunnel = await verdict(.status(.wstunnelFailed))
        var wstunnelDown = false
        if case TunnelManagementError.resetLayerDown? = wstunnel { wstunnelDown = true }
        check(wstunnelDown, "a wstunnel that did not come back is the same layer-down error (\(wstunnel?.localizedDescription ?? "no error"))")
        let skipped = await verdict(.status(.skipped))
        var nothingToRebuild = false
        if case TunnelManagementError.resetNothingToRebuild? = skipped { nothingToRebuild = true }
        check(nothingToRebuild, "an extension with no layer to rebuild says so (\(skipped?.localizedDescription ?? "no error"))")
        let legacy = await verdict(.legacy)
        check(legacy == nil, "a reply without an outcome byte returns with no error (\(legacy?.localizedDescription ?? "no error"))")
        let unknown = await verdict(.rawStatus(200))
        var named = false
        if case TunnelManagementError.resetOutcomeUnrecognised(let raw)? = unknown { named = raw == 200 }
        check(named, "an unknown outcome byte is named with its value (\(unknown?.localizedDescription ?? "no error"))")
        check(fake.providerMessageCount == 6,
              "all six verdicts came from a message that was really sent (messages=\(fake.providerMessageCount))")
    }

    func aResetNobodyAnswersEndsItsOwnWait() async {
        guard let rig = rig("ResetMute", [.connected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])
        fake.resetAnswer = .silent

        let start = Date()
        let thrown = await resetVerdict(manager, row)
        let elapsed = Date().timeIntervalSince(start)
        var unanswered = false
        if case TunnelManagementError.resetUnanswered? = thrown { unanswered = true }
        check(unanswered, "the wait ends with the silence named (\(thrown?.localizedDescription ?? "no error"))")
        check(fake.providerMessageCount == 1, "after the message was sent (messages=\(fake.providerMessageCount))")
        check(elapsed >= 8 && elapsed < 20,
              "on its budget, neither early nor hanging (took \(String(format: "%.1f", elapsed))s)")
        check(row.status == .active, "and the row is left active (status=\(row.status))")
    }

    func aResetTheSessionRefusesToSendIsNamed() async {
        guard let rig = rig("ResetSend", [.connected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])
        fake.messageFailure = NSError(domain: "TE.Seam", code: 61,
                                      userInfo: [NSLocalizedDescriptionKey: "test rig refused the message"])

        let thrown = await resetVerdict(manager, row)
        var refused = false
        if case TunnelManagementError.resetSendFailed(let description)? = thrown {
            refused = description == "test rig refused the message"
        }
        check(refused, "the reset fails as a refused send carrying the system's description (\(thrown.map { String(describing: $0) } ?? "no error"))")
    }

    func aResetOnARestingRowSendsNothing() async {
        guard let rig = rig("ResetRest", [.disconnected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])

        let thrown = await resetVerdict(manager, row)
        check(thrown == nil && fake.providerMessageCount == 0,
              "a reset on an inactive row returns without an error and sends no message"
              + " (error=\(thrown?.localizedDescription ?? "none"), messages=\(fake.providerMessageCount))")
    }
}
#endif
