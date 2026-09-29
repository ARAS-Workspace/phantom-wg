import Foundation

// MARK: - Reset (Layer-Level)

extension TunnelsManager {

    /// Ask the extension to restart its tunnel layer (wstunnel +
    /// WireGuard in ghost mode, WireGuard alone in standalone) in
    /// place — the `utun` interface and its routes stay up, so
    /// nothing leaks out onto the physical NIC while the layer is
    /// rebuilt. Triggered by the user's "Reset Connection" button
    /// when the tunnel appears stuck.
    ///
    /// Extension uses opcode `3` and answers with the outcome of the
    /// whole stop/start sequence, so returning without throwing means
    /// the layer was rebuilt (the WireGuard handshake itself may still
    /// be settling). Every other ending throws, because a reset that
    /// left the layer down looks exactly like a working one from the
    /// outside: `utun` is up, the row still says the tunnel is on, and
    /// not a packet is moving. Three ways for the reply not to arrive
    /// are named separately from the layer's own verdict — the send
    /// itself failing, no answer inside the budget, and an outcome
    /// byte this build does not know — because each leaves the tunnel
    /// in a different state and only the user can pick the next move.
    /// A reply too short to carry an outcome is an older extension:
    /// nothing is claimed about it and nothing is thrown.
    func resetConnection(of tunnel: TunnelContainer) async throws {
        guard tunnel.status == .active || tunnel.status == .reasserting else { return }

        let outcome: ResetOutcome = await withCheckedContinuation { continuation in
            let resume = SingleResume(continuation)
            do {
                try tunnel.tunnelProvider.sendProviderMessage(Data([3])) { data in
                    resume.finish(.answered(TunnelResetReply.read(data)))
                }
            } catch {
                resume.finish(.sendFailed(error.localizedDescription))
                return
            }
            // The extension is not asked to hurry and the message is
            // never withdrawn — the budget only ends the *wait*. A
            // reply that lands after it finds the slot taken, so a
            // late answer cannot contradict what the user was already
            // told.
            Task {
                try? await Task.sleep(for: .seconds(Self.resetBudget))
                resume.finish(.unanswered)
            }
        }

        switch outcome {
        case .answered(let reading):
            switch reading {
            case .absent:
                return
            case .outcome(let reply):
                if let failure = TunnelManagementError.forReset(reply) { throw failure }
            case .unrecognised(let raw):
                throw TunnelManagementError.resetOutcomeUnrecognised(raw: raw)
            }
        case .sendFailed(let description):
            throw TunnelManagementError.resetSendFailed(systemError: description)
        case .unanswered:
            throw TunnelManagementError.resetUnanswered
        }
    }

    private nonisolated static let resetBudget: TimeInterval = 10
}

private enum ResetOutcome: Sendable {
    case answered(TunnelResetReply.Reading)
    case sendFailed(String)
    case unanswered
}
