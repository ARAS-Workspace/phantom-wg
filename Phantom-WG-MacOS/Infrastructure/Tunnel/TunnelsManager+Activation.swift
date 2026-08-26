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
        guard tunnel.status == .inactive || tunnel.status == .unknown else { return }
        beginActivation(of: tunnel)
    }

    /// A slot claimed while a teardown holds the store is one whose sweep has
    /// already passed: nothing will hand it on, and the stop this would issue
    /// lands on a session the teardown is about to take anyway.
    /// @witness ActivationSeam.anUnknownOccupantDoesNotBarTheQueue
    /// @witness ActivationSeam.aTeardownHoldingTheStoreTakesNoQueueSlot
    func beginActivation(of tunnel: TunnelContainer) {
        guard !refreshSuspended else { return }
        guard !removingIds.contains(tunnel.id) else { return }
        guard tunnel.status == .inactive || tunnel.status == .unknown else { return }

        if let activeTunnel = tunnels.first(where: { $0.id != tunnel.id && occupiesSlot($0) }) {
            if let previousWaiting = waitingTunnel, previousWaiting.id != tunnel.id {
                withdrawQueueSlot(previousWaiting)
            }
            tunnel.status = .waiting
            waitingTunnel = tunnel
            startDeactivation(of: activeTunnel)
            return
        }

        startActivation(of: tunnel, at: 0)
    }

    /// @witness ActivationSeam
    /// @witness PhantomTunnel
    /// @witness RecoverySwitch
    /// @witness Unreachable
    /// @witness ActivationSeam.aStopTheRuleSaveCannotAnswerStillGoesOut
    func startDeactivation(of tunnel: TunnelContainer) {
        guard tunnel.status != .inactive && tunnel.status != .deactivating
                && tunnel.status != .unknown else { return }

        tunnel.isAttemptingActivation = false
        tunnel.activationAttemptId = nil
        tunnel.activationTask?.cancel()
        tunnel.activationTask = nil
        if case .connectedDespiteStopRequest = tunnel.lastActivationError {
            tunnel.lastActivationError = nil
        }

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
                if case .unanswered = outcome {
                    tunnel.lastActivationError = .stopRuleStandDownUnconfirmed
                }
                performDeactivation(of: tunnel)
            }
            park(disarm, on: tunnel)
        } else {
            performDeactivation(of: tunnel)
            repairRuleAfterStop(tunnel)
        }
    }

    /// Fighting the rule is a loop: a session it brings back after our stop is
    /// SHOWN and said, never stopped again on the user's behalf. Try-again is
    /// the toggle itself.
    /// @witness ActivationSeam.aSessionTheRuleBringsBackIsShownNotFought
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
            case .unanswered:
                if tunnel.status == .inactive || tunnel.status == .deactivating {
                    tunnel.lastActivationError = .stopRuleStandDownUnconfirmed
                }
            case .done:
                tunnel.clearStopRefusalOnceDisarmed()
                if tunnel.status == .active || tunnel.status == .reasserting
                    || tunnel.status == .activating {
                    tunnel.lastActivationError = .connectedDespiteStopRequest
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
    /// @witness ActivationSeam.aTeardownWaitsOutTheStopItParked
    func disarmAllRecovery() async {
        waitingTunnel = nil
        for tunnel in tunnels {
            tunnel.isAttemptingActivation = false
            tunnel.activationAttemptId = nil
            tunnel.activationTask?.cancel()
            tunnel.activationTask = nil
        }
        // Read each row's deferred work INSIDE the wait rather than snapshotting
        // it first: `park(_:on:)` replaces `pendingDisarmTask` with a fresh
        // wrapper, so a handle taken before the await can complete without
        // covering the one that replaced it.
        let settled = await bounded(15) {
            for tunnel in self.tunnels {
                await tunnel.activationRungTask?.value
                await tunnel.pendingDisarmTask?.value
            }
            return true
        }
        if settled != true {
            NSLog("[uninstall] the recovery sweep gave up waiting on the deferred work of \(tunnels.count) row(s) after 15s — whatever resumes past here writes behind the sweep rather than in front of it")
        }
        // A stop that resumed inside the wait above has painted its own row,
        // so the verdict is reached after it. It is a flat one: the sweep has
        // issued no stop and is not a reading of the session, so the
        // provider's answer here is whatever NE has not caught up on yet —
        // and a row left anything but inactive holds the single slot against
        // every tunnel including itself.
        for tunnel in tunnels {
            switch tunnel.status {
            case .activating, .waiting, .deactivating:
                tunnel.status = .inactive
            case .inactive, .active, .reasserting, .unknown:
                break
            }
        }
        for tunnel in tunnels {
            guard mayWriteStore(tunnel) else {
                NSLog("[uninstall] recovery sweep skipped \(tunnel.name): it is being removed, or the list no longer holds it")
                continue
            }
            switch await Self.standDownRecovery(on: tunnel.tunnelProvider) {
            case .done:
                break
            case .refused(let error):
                NSLog("[uninstall] disarm save refused on \(tunnel.name) — armed=\(tunnel.tunnelProvider.isOnDemandEnabled) is the truest reading available: \(error.localizedDescription)")
            case .unanswered:
                NSLog("[uninstall] disarm save on \(tunnel.name) has not answered — the sweep moves on and the save keeps running behind it, feeding no decision")
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

    enum DisarmAnswer {
        case done
        case refused(Error)
        case unanswered
    }

    /// The one bound on the one call nobody can cancel. The save is never
    /// cancelled and never assumed: the wait on it ends at the user's
    /// patience, and a save that has not answered by then keeps running on
    /// its own — its late answer feeds no decision anywhere.
    /// @witness ActivationSeam.aStopTheRuleSaveCannotAnswerStillGoesOut
    @discardableResult
    static func standDownRecovery(on provider: TunnelProviding) async -> DisarmAnswer {
        let wasArmed = provider.isOnDemandEnabled
        provider.isOnDemandEnabled = false
        let save = Task { () -> Error? in
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
        // The same one-shot bridge `bounded(_:_:)` is built on. A task group
        // cannot race this wait: leaving a group awaits every child, and
        // `Task.value` ignores its awaiter's cancellation, so a group with the
        // save inside it only returns when the save does.
        let landed: Error?? = await withCheckedContinuation { continuation in
            let resume = SingleResume(continuation)
            Task { @MainActor in resume.finish(await save.value) }
            Task {
                try? await Task.sleep(for: .seconds(Self.disarmPatience))
                resume.finish(nil)
            }
        }
        guard let answer = landed else {
            NSLog("[activation] the disarm save on \(provider.localizedDescription ?? "?") has not answered within \(Int(Self.disarmPatience))s — proceeding without it; the save keeps running and its late answer feeds no decision")
            return .unanswered
        }
        if let error = answer {
            return .refused(error)
        }
        return .done
    }

    enum StandDownOutcome {
        case barred
        case done
        case refused(Error)
        case unanswered
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
        switch await Self.standDownRecovery(on: tunnel.tunnelProvider) {
        case .done:
            return .done
        case .unanswered:
            return .unanswered
        case .refused(let error):
            if loggingRefusal {
                Self.logDisarmRefusal(on: tunnel, context(), error)
            }
            return .refused(error)
        }
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
        case .inactive, .deactivating, .unknown:
            return true
        }
    }

    private static func standDownAfterGiveUp(_ tunnel: TunnelContainer, _ context: String) async {
        switch await standDownRecovery(on: tunnel.tunnelProvider) {
        case .done:
            break
        case .refused(let error):
            logDisarmRefusal(on: tunnel, context, error)
        case .unanswered:
            NSLog("[activation] disarm save on \(tunnel.name) \(context) has not answered — left running, nothing decided on it")
        }
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

    /// @witness ActivationSeam.aTeardownHoldingTheStoreArmsNothing
    /// @witness ActivationSeam.aRungAlreadyPastTheEntryArmsNothingEither
    /// @witness ActivationSeam.aRowTheListDroppedRaisesNoSessionEither
    func mayArmRecovery(_ tunnel: TunnelContainer) -> Bool {
        !refreshSuspended && mayWriteStore(tunnel)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func startActivation(of tunnel: TunnelContainer, at retryIndex: Int) {
        guard mayArmRecovery(tunnel) else { return }
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
            guard mayArmRecovery(tunnel) else { return }

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
        guard mayArmRecovery(tunnel) else { return }

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

    /// "Deactivating" is a fact about US, not a claim about NE: the stop went
    /// out and no terminal answer has been seen. Nothing waits behind the
    /// paint — the next reading through any door repaints the row freely, and
    /// every gate reads the live status rather than this one.
    /// @witness ActivationSeam.aStopTheRuleSaveCannotAnswerStillGoesOut
    /// @witness ActivationSeam.aSecondPressQueuesBehindAStopStillLanding
    func performDeactivation(of tunnel: TunnelContainer) {
        tunnel.tunnelProvider.stopTunnel()
        tunnel.stopIssuedAt = ContinuousClock.now

        if tunnel.tunnelProvider.connectionStatus == .disconnected {
            tunnel.status = .inactive
            activateWaitingTunnelIfNeeded()
        } else {
            tunnel.status = .deactivating
        }
    }

    /// The slot question is asked of the LIVE reading, never of a painted
    /// status: a reading the system has already walked away from (.invalid,
    /// .disconnected) does not occupy the slot, whatever the row still shows.
    /// .disconnecting occupies it only inside the stop-landing window — a
    /// timestamp closed by arithmetic, so a stop the system never finishes
    /// cannot pin the queue for ever.
    /// @witness ActivationSeam.anUnknownOccupantDoesNotBarTheQueue
    /// @witness ActivationSeam.aSecondPressQueuesBehindAStopStillLanding
    private func occupiesSlot(_ tunnel: TunnelContainer) -> Bool {
        if tunnel.isAttemptingActivation { return true }
        switch tunnel.tunnelProvider.connectionStatus {
        case .connected, .connecting, .reasserting:
            return true
        case .disconnecting:
            guard let issued = tunnel.stopIssuedAt else { return false }
            return ContinuousClock.now - issued < .seconds(Self.disarmPatience)
        default:
            return false
        }
    }

    /// @witness ActivationSeam.aTeardownHoldingTheStoreTakesNoHandOff
    func activateWaitingTunnelIfNeeded() {
        guard !refreshSuspended else { return }
        guard let waitingTunnel else { return }
        guard tunnels.contains(where: { $0 === waitingTunnel }) else {
            self.waitingTunnel = nil
            return
        }
        guard !tunnels.contains(where: {
            $0.id != waitingTunnel.id && occupiesSlot($0)
        }) else { return }
        self.waitingTunnel = nil
        guard waitingTunnel.status == .waiting else { return }
        startActivation(of: waitingTunnel, at: 0)
    }

    /// How long a person waits before "this app is stuck": the bound on the
    /// disarm save's wait and the width of the stop-landing window, from the
    /// user surface rather than from anything NE promises.
    nonisolated static let disarmPatience: TimeInterval = 3
}
