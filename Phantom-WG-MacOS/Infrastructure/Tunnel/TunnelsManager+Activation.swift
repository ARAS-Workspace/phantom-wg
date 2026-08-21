import Foundation
import NetworkExtension

// MARK: - Activation & Deactivation

extension TunnelsManager {

    /// @witness ActivationSeam
    /// @witness ConfigContract
    /// @witness Isolation
    /// @witness PhantomTunnel
    /// @witness RecoverySwitch
    /// @witness Unreachable
    func startActivation(of tunnel: TunnelContainer) {
        guard !removingIds.contains(tunnel.id) else { return }
        guard tunnel.status == .inactive else { return }
        for other in tunnels {
            other.respawnReviveConsumed = true
            other.respawnReviveTask?.cancel()
            other.respawnReviveTask = nil
        }
        tunnel.respawnReviveConsumed = false
        beginActivation(of: tunnel)
    }

    func beginActivation(of tunnel: TunnelContainer) {
        guard !removingIds.contains(tunnel.id) else { return }
        guard tunnel.status == .inactive else { return }

        if let activeTunnel = tunnels.first(where: { $0.status != .inactive && $0.status != .waiting }) {
            if let previousWaiting = waitingTunnel, previousWaiting.id != tunnel.id {
                withdrawQueueSlot(previousWaiting)
            }
            tunnel.status = .waiting
            waitingTunnel = tunnel
            startDeactivation(of: activeTunnel)
            activateWaitingTunnelIfNeeded()
            return
        }

        startActivation(of: tunnel, at: 0)
    }

    /// @witness ActivationSeam
    /// @witness PhantomTunnel
    /// @witness RecoverySwitch
    /// @witness Unreachable
    func startDeactivation(of tunnel: TunnelContainer) {
        tunnel.respawnReviveConsumed = true
        tunnel.respawnReviveTask?.cancel()
        tunnel.respawnReviveTask = nil
        guard tunnel.status != .inactive && tunnel.status != .deactivating else { return }

        tunnel.isAttemptingActivation = false
        tunnel.activationAttemptId = nil
        tunnel.activationTask?.cancel()
        tunnel.activationTask = nil

        if tunnel.status == .waiting {
            withdrawQueueSlot(tunnel)
            return
        }

        if tunnel.isActivateOnDemandEnabled {
            tunnel.pendingDisarmCount += 1
            let disarm = Task {
                defer { tunnel.pendingDisarmCount -= 1 }
                let outcome = await guardedStandDown(tunnel, loggingRefusal: false)
                if case .barred = outcome { return }
                guard tunnel.activationAttemptId == nil else { return }
                if case .done = outcome {
                    tunnel.clearStopRefusalOnceDisarmed()
                }
                if case .refused(let disarmError) = outcome {
                    tunnel.lastActivationError = .stopDisarmRefused(systemError: disarmError)
                }
                performDeactivation(of: tunnel)
            }
            park(disarm, on: tunnel)
        } else {
            performDeactivation(of: tunnel)
            repairRuleAfterStop(tunnel)
        }
    }

    private func repairRuleAfterStop(_ tunnel: TunnelContainer) {
        let repair = Task {
            guard tunnel.activationAttemptId == nil else { return }
            let outcome = await guardedStandDown(tunnel, loggingRefusal: false)
            guard tunnel.activationAttemptId == nil else { return }
            switch outcome {
            case .barred:
                break
            case .refused(let disarmError):
                if tunnel.status == .inactive || tunnel.status == .deactivating {
                    tunnel.lastActivationError = .stopDisarmRefused(systemError: disarmError)
                }
            case .done:
                tunnel.clearStopRefusalOnceDisarmed()
                if tunnel.status == .active || tunnel.status == .reasserting
                    || tunnel.status == .activating {
                    performDeactivation(of: tunnel)
                }
            }
        }
        park(repair, on: tunnel)
    }

    private func park(_ disarm: Task<Void, Never>, on tunnel: TunnelContainer) {
        let previous = tunnel.pendingDisarmTask
        tunnel.pendingDisarmTask = Task {
            await previous?.value
            await disarm.value
        }
    }

    /// @witness RecoverySwitch
    /// @witness Unreachable
    /// @witness VaultIntegrity
    func disarmAllRecovery() async {
        waitingTunnel = nil
        for tunnel in tunnels {
            tunnel.isAttemptingActivation = false
            tunnel.activationAttemptId = nil
            tunnel.activationTask?.cancel()
            tunnel.activationTask = nil
            tunnel.respawnReviveConsumed = true
            tunnel.respawnReviveTask?.cancel()
            tunnel.respawnReviveTask = nil
            if tunnel.status == .activating || tunnel.status == .waiting {
                tunnel.status = .inactive
            }
        }
        let rungs = tunnels.compactMap(\.activationRungTask)
        _ = await bounded(15) {
            for rung in rungs { await rung.value }
            return true
        }
        for tunnel in tunnels {
            guard mayWriteStore(tunnel) else {
                NSLog("[uninstall] recovery sweep skipped \(tunnel.name): it is being removed, or the list no longer holds it")
                continue
            }
            if let error = await Self.standDownRecovery(on: tunnel.tunnelProvider) {
                NSLog("[uninstall] disarm save refused on \(tunnel.name) — armed=\(tunnel.tunnelProvider.isOnDemandEnabled) is the truest reading available: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Recovery Rule & Activation Machinery

    private static func armRecovery(on provider: TunnelProviding) {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        provider.onDemandRules = [rule]
        provider.isOnDemandEnabled = true
    }

    @discardableResult
    static func standDownRecovery(on provider: TunnelProviding) async -> Error? {
        let wasArmed = provider.isOnDemandEnabled
        provider.isOnDemandEnabled = false
        do {
            try await provider.savePreferences()
            return nil
        } catch {
            if (try? await provider.loadPreferences()) == nil {
                provider.isOnDemandEnabled = wasArmed
            }
            return error
        }
    }

    enum StandDownOutcome {
        case barred
        case done
        case refused(Error)
    }

    func standDownForSlotGate(id: UUID, context: @autoclosure () -> String) async -> StandDownOutcome {
        guard let tunnel = tunnels.first(where: { $0.id == id }) else { return .barred }
        return await guardedStandDown(tunnel, context: context())
    }

    @discardableResult
    func guardedStandDown(
        _ tunnel: TunnelContainer,
        context: @autoclosure () -> String = "",
        loggingRefusal: Bool = true
    ) async -> StandDownOutcome {
        guard !removingIds.contains(tunnel.id),
              tunnels.contains(where: { $0 === tunnel }) else { return .barred }
        guard let error = await Self.standDownRecovery(on: tunnel.tunnelProvider) else {
            return .done
        }
        if loggingRefusal {
            Self.logDisarmRefusal(on: tunnel, context(), error)
        }
        return .refused(error)
    }

    private func groundedAfterGiveUp(_ tunnel: TunnelContainer,
                                     _ reason: @autoclosure () -> String) -> Bool {
        tunnel.refreshStatus()
        switch tunnel.status {
        case .active, .reasserting:
            NSLog("[activation] the system answered while \(tunnel.name) was giving up (\(reason())) — leaving the session to it")
            return false
        case .waiting:
            NSLog("[activation] the queue took \(tunnel.name) while it was giving up (\(reason())) — leaving the row to its slot")
            return false
        case .activating:
            tunnel.status = .inactive
            return true
        case .inactive, .deactivating:
            return true
        }
    }

    private static func standDownAfterGiveUp(_ tunnel: TunnelContainer, _ context: String) async {
        guard let error = await standDownRecovery(on: tunnel.tunnelProvider) else { return }
        logDisarmRefusal(on: tunnel, context, error)
    }

    private static func logDisarmRefusal(on tunnel: TunnelContainer, _ context: String, _ error: Error) {
        let suffix = context.isEmpty ? "" : " \(context)"
        NSLog("[activation] disarm save refused on \(tunnel.name)\(suffix) — armed=\(tunnel.tunnelProvider.isOnDemandEnabled) is the truest reading available: \(error.localizedDescription)")
    }

    private func withdrawQueueSlot(_ tunnel: TunnelContainer) {
        if waitingTunnel?.id == tunnel.id { waitingTunnel = nil }
        tunnel.isAttemptingActivation = false
        tunnel.activationAttemptId = nil
        tunnel.activationTask?.cancel()
        tunnel.activationTask = nil
        guard tunnel.status == .waiting else {
            tunnel.refreshStatus()
            return
        }
        tunnel.status = .inactive
    }

    func mayWriteStore(_ tunnel: TunnelContainer) -> Bool {
        !removingIds.contains(tunnel.id) && tunnels.contains(where: { $0 === tunnel })
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func startActivation(of tunnel: TunnelContainer, at retryIndex: Int) {
        guard !removingIds.contains(tunnel.id) else { return }
        guard retryIndex < maxRetries else {
            tunnel.isAttemptingActivation = false
            tunnel.activationAttemptId = nil
            tunnel.activationTask?.cancel()
            tunnel.activationTask = nil
            guard groundedAfterGiveUp(tunnel, "the ladder ran out") else { return }
            tunnel.lastActivationError = .retryLimitReached(
                lastSystemError: TunnelsManager.noSystemDetail(LocalizationManager.shared.t("error_detail_timeout")))
            activateWaitingTunnelIfNeeded()
            return
        }

        if retryIndex == 0 {
            for other in tunnels where other.id != tunnel.id {
                Task {
                    await guardedStandDown(other, context: "during another tunnel's rung 0")
                }
            }

            tunnel.status = .activating
            tunnel.lastActivationError = nil
        }

        tunnel.isAttemptingActivation = true
        let attemptId = UUID().uuidString
        tunnel.activationAttemptId = attemptId

        Task { [weak self] in
            guard let ceiling = self?.activationCeiling else { return }
            try? await Task.sleep(for: .seconds(ceiling))
            guard let self,
                  tunnel.activationAttemptId == attemptId,
                  tunnel.isAttemptingActivation,
                  tunnel.lastActivationError == nil,
                  tunnel.status == .activating || tunnel.status == .reasserting
                    || tunnel.status == .deactivating || tunnel.status == .inactive,
                  !self.removingIds.contains(tunnel.id),
                  self.tunnels.contains(where: { $0 === tunnel }) else { return }
            let derived = TunnelStatus(from: tunnel.tunnelProvider.connectionStatus)
            guard derived == .inactive || derived == .deactivating else { return }
            NSLog("[activation] attempt on \(tunnel.name) never resolved — withdrawing it")
            tunnel.isAttemptingActivation = false
            tunnel.activationAttemptId = nil
            tunnel.activationTask?.cancel()
            tunnel.activationTask = nil
            tunnel.refreshStatus()
            guard tunnel.status == .inactive || tunnel.status == .deactivating else {
                NSLog("[activation] the system answered while \(tunnel.name) was being withdrawn — leaving the session to it")
                return
            }
            tunnel.lastActivationError = .activationUnresolved
            self.activateWaitingTunnelIfNeeded()
            await self.guardedStandDown(tunnel, context: "after an unresolved attempt")
        }

        tunnel.activationRungTask = Task {
            if retryIndex == 0, case .heldByForeign = await foreignSlotVerdict(within: preflightBudget) {
                guard tunnel.activationAttemptId == attemptId,
                      tunnel.status == .activating else { return }
                tunnel.isAttemptingActivation = false
                if groundedAfterGiveUp(tunnel, "a proven foreign holder") {
                    tunnel.lastActivationError = .foreignSlotHolder
                    activateWaitingTunnelIfNeeded()
                }
                await Self.standDownAfterGiveUp(tunnel, "at the rung-0 pre-flight, after a proven foreign holder")
                return
            }
            guard tunnel.activationAttemptId == attemptId,
                  tunnel.status == .activating || tunnel.status == .reasserting else { return }

            tunnel.tunnelProvider.isEnabled = true
            Self.armRecovery(on: tunnel.tunnelProvider)
            do {
                try await tunnel.tunnelProvider.savePreferences()
                guard tunnel.activationAttemptId == attemptId,
                      tunnel.status == .activating || tunnel.status == .reasserting else { return }
                await self.doStartVPNTunnel(tunnel: tunnel, attemptId: attemptId, retryIndex: retryIndex)
            } catch {
                guard tunnel.activationAttemptId == attemptId else { return }
                tunnel.isAttemptingActivation = false
                tunnel.refreshStatus()
                guard tunnel.status == .inactive || tunnel.status == .deactivating else {
                    NSLog("[activation] arm save refused on \(tunnel.name) but the row has moved on (status=\(tunnel.status)) — leaving it be")
                    return
                }
                tunnel.lastActivationError = .savingFailed(systemError: error)
                activateWaitingTunnelIfNeeded()
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func doStartVPNTunnel(tunnel: TunnelContainer, attemptId: String, retryIndex: Int) async {
        do {
            try await tunnel.tunnelProvider.loadPreferences()
        } catch {
            if tunnel.activationAttemptId == attemptId || tunnel.activationAttemptId == nil {
                await Self.standDownAfterGiveUp(tunnel, "after a configuration that would not load")
            }
            guard tunnel.activationAttemptId == attemptId else { return }
            tunnel.isAttemptingActivation = false
            guard groundedAfterGiveUp(tunnel, "a configuration that would not load") else { return }
            tunnel.lastActivationError = .loadingFailed(systemError: error)
            activateWaitingTunnelIfNeeded()
            return
        }

        guard tunnel.activationAttemptId == attemptId,
              tunnel.status == .activating || tunnel.status == .reasserting else { return }

        do {
            try tunnel.tunnelProvider.startTunnel()
        } catch {
            if retryIndex == 0,
               (error as? NEVPNError)?.code == .configurationStale,
               tunnel.activationAttemptId == attemptId,
               (try? await tunnel.tunnelProvider.loadPreferences()) != nil {
                guard tunnel.activationAttemptId == attemptId,
                      tunnel.status == .activating || tunnel.status == .reasserting else { return }
                startActivation(of: tunnel, at: retryIndex + 1)
                return
            }
            let verdict = await foreignSlotVerdict(within: preflightBudget)
            guard tunnel.activationAttemptId == attemptId,
                  tunnel.status == .activating || tunnel.status == .reasserting else { return }
            if case .heldByForeign = verdict {
                tunnel.isAttemptingActivation = false
                if groundedAfterGiveUp(tunnel, "a proven foreign holder") {
                    tunnel.lastActivationError = .foreignSlotHolder
                    activateWaitingTunnelIfNeeded()
                }
                await Self.standDownAfterGiveUp(tunnel, "in the start-catch, after a proven foreign holder")
                return
            }
            tunnel.isAttemptingActivation = false
            guard groundedAfterGiveUp(tunnel, "a start the system refused") else { return }
            tunnel.lastActivationError = .startingFailed(systemError: error)
            activateWaitingTunnelIfNeeded()
            await Self.standDownAfterGiveUp(tunnel, "after a local give-up")
            return
        }

        tunnel.activationTask?.cancel()
        let tunnelId = tunnel.id
        tunnel.activationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.retryInterval ?? 5.0))
            } catch {
                return
            }
            guard let self,
                  let tunnel = self.tunnels.first(where: { $0.id == tunnelId }),
                  tunnel.activationAttemptId == attemptId else { return }
            if tunnel.status == .activating || tunnel.status == .reasserting {
                self.startActivation(of: tunnel, at: retryIndex + 1)
            }
        }
    }

    func performDeactivation(of tunnel: TunnelContainer) {

        tunnel.tunnelProvider.stopTunnel()

        switch tunnel.tunnelProvider.connectionStatus {
        case .disconnected:
            tunnel.status = .inactive
            activateWaitingTunnelIfNeeded()
        case .invalid:
            tunnel.status = .inactive
        default:
            tunnel.status = .deactivating
        }
    }

    func activateWaitingTunnelIfNeeded() {
        guard let waitingTunnel else { return }
        guard tunnels.contains(where: { $0 === waitingTunnel }) else {
            self.waitingTunnel = nil
            return
        }
        guard !tunnels.contains(where: {
            $0.id != waitingTunnel.id && $0.status != .inactive && $0.status != .waiting
        }) else { return }
        self.waitingTunnel = nil
        guard waitingTunnel.status == .waiting else { return }
        startActivation(of: waitingTunnel, at: 0)
    }

    // MARK: - Reset (Layer-Level)

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
