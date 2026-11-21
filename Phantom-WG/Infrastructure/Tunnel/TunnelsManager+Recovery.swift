import NetworkExtension

/// The recovery rule's arming and stand-down, kept beside the activation
/// paths in `TunnelsManager.swift` that call them.
extension TunnelsManager {

    /// The recovery rule: one connect-on-any-network on-demand rule,
    /// armed on every activation. There is no user-facing switch —
    /// starting a tunnel is the recovery intent, stopping it withdraws
    /// it (`startDeactivation` disarms before it stops).
    /// @witness ActivationSeam.theArmedRuleIsOneConnectRuleForAnyInterface
    /// @witness PhantomTunnel.activate
    /// @witness RecoverySwitch.armFirst
    /// @witness RecoverySwitch.switchToSecond
    static func armRecovery(on provider: TunnelProviding) {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        provider.onDemandRules = [rule]
        provider.isOnDemandEnabled = true
    }

    /// Stands the recovery rule down and persists it. Used only on the
    /// give-up paths that failed *locally* — a config that cannot load,
    /// or whose `startTunnel` throws, would fail the same way on every
    /// system-initiated on-demand retry, so leaving it armed is a loop
    /// trap. A timeout or a dropped session is the opposite case: that
    /// is the transient condition the recovery rule exists to ride out,
    /// so those paths leave it armed on purpose.
    ///
    /// Returns the error when the save was refused; `nil` when it landed
    /// or did not answer within `disarmPatience`, after which the give-up
    /// goes on to the queue hand-off. The give-up paths that call this
    /// already carry the user's answer — why the activation failed — so
    /// none of them replaces that sentence with the rule's fate. The
    /// refusal is handed back rather than swallowed so that choice is
    /// written down at the call site instead of hiding inside a `try?`.
    @discardableResult
    static func disarmRecovery(on provider: TunnelProviding) async -> Error? {
        if case .refused(let error) = await standDownRecovery(on: provider) {
            return error
        }
        return nil
    }

    /// How long a person waits before "this app is stuck" (Mac 2.2.1's
    /// `disarmPatience`): the bound on the wait for a stand-down save.
    nonisolated static let disarmPatience: TimeInterval = 3

    enum DisarmAnswer {
        case done
        case refused(Error)
        case unanswered
    }

    /// Writes the recovery rule down and saves it, waiting on the save's
    /// answer no longer than `disarmPatience`. The save is never
    /// cancelled: one that has not answered by then runs on, and no flow
    /// here reads its late answer.
    /// @witness ActivationSeam.aStopTheRuleSaveCannotAnswerStillGoesOut
    /// @witness ActivationSeam.aGiveUpWhoseDisarmSaveHangsStillHandsTheQueueOn
    static func standDownRecovery(on provider: TunnelProviding) async -> DisarmAnswer {
        provider.isOnDemandEnabled = false
        let save = Task { () -> Error? in
            do {
                try await provider.savePreferences()
                return nil
            } catch {
                return error
            }
        }
        let landed: Error?? = await withCheckedContinuation { continuation in
            let resume = SingleResume(continuation)
            Task { @MainActor in resume.finish(await save.value) }
            Task {
                try? await Task.sleep(for: .seconds(Self.disarmPatience))
                resume.finish(nil)
            }
        }
        guard let answer = landed else { return .unanswered }
        if let error = answer { return .refused(error) }
        return .done
    }
}
