import Foundation
import NetworkExtension

// MARK: - Activation & Deactivation

extension TunnelsManager {

    func startActivation(of tunnel: TunnelContainer) {
        guard tunnel.status == .inactive else { return }

        if let activeTunnel = tunnels.first(where: { $0.status != .inactive && $0.status != .waiting }) {
            if let previousWaiting = waitingTunnel, previousWaiting.id != tunnel.id {
                previousWaiting.status = .inactive
            }
            tunnel.status = .waiting
            waitingTunnel = tunnel
            startDeactivation(of: activeTunnel)
            return
        }

        // Disarm every other tunnel's recovery rule first — recovery
        // belongs to the tunnel being activated now
        tunnels.filter { $0.id != tunnel.id && $0.isActivateOnDemandEnabled }.forEach { other in
            other.tunnelProvider.isOnDemandEnabled = false
            other.tunnelProvider.savePreferences { _ in }
        }

        startActivation(of: tunnel, at: 0)
    }

    func startDeactivation(of tunnel: TunnelContainer) {
        guard tunnel.status != .inactive && tunnel.status != .deactivating else { return }

        // Stand the recovery rule down first — with it armed, the
        // system would reconnect the moment the tunnel drops.
        if tunnel.isActivateOnDemandEnabled {
            tunnel.tunnelProvider.isOnDemandEnabled = false
            Task {
                do {
                    try await tunnel.tunnelProvider.savePreferences()
                    performDeactivation(of: tunnel)
                } catch {
                    // The tunnel keeps running and stays armed — a
                    // fact, not a choice: the stop request could not
                    // be persisted. Surface it instead of pretending.
                    tunnel.lastActivationError = .savingFailed(systemError: error)
                }
            }
        } else {
            performDeactivation(of: tunnel)
        }
    }

    /// Uninstall-path sweep: stands every tunnel's recovery rule down.
    /// The tunnel entries themselves stay behind (removing each would
    /// raise its own consent prompt), and an armed rule on an orphaned
    /// entry would keep asking the system to revive a tunnel whose
    /// extension is about to be gone. Best-effort, like the rest of
    /// the uninstall path.
    func disarmAllRecovery() async {
        for tunnel in tunnels where tunnel.isActivateOnDemandEnabled {
            tunnel.tunnelProvider.isOnDemandEnabled = false
            try? await tunnel.tunnelProvider.savePreferences()
        }
    }

    // MARK: - Private

    /// The recovery rule: one connect-on-any-network on-demand rule,
    /// armed on every activation. There is no user-facing switch —
    /// starting a tunnel is the recovery intent, stopping it withdraws
    /// it (`startDeactivation` disarms before it stops).
    private static func armRecovery(on provider: TunnelProviding) {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        provider.onDemandRules = [rule]
        provider.isOnDemandEnabled = true
    }

    func startActivation(of tunnel: TunnelContainer, at retryIndex: Int) {
        guard retryIndex < maxRetries else {
            tunnel.isAttemptingActivation = false
            tunnel.activationTask?.cancel()
            tunnel.activationTask = nil
            tunnel.status = .inactive
            // Every attempt started without throwing and the system
            // never reported connected or disconnected — there is no
            // system error to show, only the timeout itself.
            tunnel.lastActivationError = .retryLimitReached(
                lastSystemError: TunnelsManager.noSystemDetail(LocalizationManager.shared.t("error_detail_timeout")))
            return
        }

        if retryIndex == 0 {
            tunnel.status = .activating
            tunnel.lastActivationError = nil
        }

        tunnel.isAttemptingActivation = true
        let attemptId = UUID().uuidString
        tunnel.activationAttemptId = attemptId

        // Enable the manager and arm recovery in the same save. An
        // activated tunnel is one the user wants back: the system
        // restarts it whenever a network returns — across reboots
        // and app termination included.
        tunnel.tunnelProvider.isEnabled = true
        Self.armRecovery(on: tunnel.tunnelProvider)
        Task {
            do {
                try await tunnel.tunnelProvider.savePreferences()
                guard tunnel.activationAttemptId == attemptId else { return }
                await self.doStartVPNTunnel(tunnel: tunnel, attemptId: attemptId, retryIndex: retryIndex)
            } catch {
                tunnel.isAttemptingActivation = false
                tunnel.status = .inactive
                tunnel.lastActivationError = .savingFailed(systemError: error)
            }
        }
    }

    func doStartVPNTunnel(tunnel: TunnelContainer, attemptId: String, retryIndex: Int) async {
        do {
            try await tunnel.tunnelProvider.loadPreferences()
        } catch {
            tunnel.isAttemptingActivation = false
            tunnel.status = .inactive
            tunnel.lastActivationError = .loadingFailed(systemError: error)
            return
        }

        guard tunnel.activationAttemptId == attemptId else { return }

        do {
            try tunnel.tunnelProvider.startTunnel()
        } catch {
            tunnel.isAttemptingActivation = false
            tunnel.status = .inactive
            tunnel.lastActivationError = .startingFailed(systemError: error)
            return
        }

        // Retry task — if still activating after interval, retry
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
        tunnel.status = .deactivating
        tunnel.tunnelProvider.stopTunnel()
    }

    func activateWaitingTunnelIfNeeded() {
        guard let waitingTunnel else { return }
        self.waitingTunnel = nil
        guard waitingTunnel.status == .waiting else { return }
        startActivation(of: waitingTunnel, at: 0)
    }

    // MARK: - Reset (Layer-Level)

    /// Ask the extension to restart its tunnel layer (wstunnel +
    /// WireGuard in ghost mode, WireGuard alone in standalone) in
    /// place — the `utun` interface and its routes stay up, so
    /// nothing leaks out onto the physical NIC while the layer is
    /// rebuilt. Triggered by the user's "Reset Connection" button
    /// when the tunnel appears stuck.
    ///
    /// Extension uses opcode `3`; the handler replies only after the
    /// full stop/start sequence completes, so this wrapper returning
    /// means the layer has been rebuilt (the WireGuard handshake
    /// itself may still be settling).
    func resetConnection(of tunnel: TunnelContainer) async throws {
        guard tunnel.status == .active || tunnel.status == .reasserting else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try tunnel.tunnelProvider.sendProviderMessage(Data([3])) { _ in
                    continuation.resume()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
