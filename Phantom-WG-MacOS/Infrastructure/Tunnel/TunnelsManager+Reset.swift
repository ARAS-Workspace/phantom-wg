import Foundation

// MARK: - Reset (Layer-Level)

extension TunnelsManager {

    /// @witness ActivationSeam
    /// @witness PhantomTunnel
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
