import Foundation
import NetworkExtension

@Observable
@MainActor
class TunnelsManager {

    var tunnels: [TunnelContainer] = []

    @ObservationIgnored private let providerFactory: TunnelProviderFactory
    @ObservationIgnored private var statusObservationToken: AnyObject?
    @ObservationIgnored private var configObservationToken: AnyObject?
    @ObservationIgnored private var waitingTunnel: TunnelContainer?

    // Activation parameters (overridable for tests)
    @ObservationIgnored var retryInterval: TimeInterval = 5.0
    @ObservationIgnored var maxRetries: Int = 8

    // MARK: - Factory

    static func create() async throws -> TunnelsManager {
        let factory = RealTunnelProviderFactory()
        let providers = try await factory.loadAllFromPreferences()
        return TunnelsManager(tunnelProviders: providers, providerFactory: factory)
    }

    init(tunnelProviders: [TunnelProviding], providerFactory: TunnelProviderFactory = RealTunnelProviderFactory()) {
        self.providerFactory = providerFactory
        tunnels = Self.sortedByCreatedAt(tunnelProviders.map { TunnelContainer(tunnel: $0) })
        startObservingTunnelStatuses()
        startObservingTunnelConfigurations()
    }

    /// Newest first — tunnels without a persisted `createdAt` fall back
    /// to `.distantPast` so they sort below freshly-created ones.
    static func sortedByCreatedAt(_ list: [TunnelContainer]) -> [TunnelContainer] {
        list.sorted {
            let lhs = $0.tunnelConfig?.createdAt ?? .distantPast
            let rhs = $1.tunnelConfig?.createdAt ?? .distantPast
            return lhs > rhs
        }
    }

    deinit {
        if let token = statusObservationToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = configObservationToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - CRUD

    func add(config: TunnelConfig, activateOnDemand: ActivateOnDemandOption = .off) async throws -> TunnelContainer {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TunnelManagementError.tunnelInvalidName
        }
        if tunnels.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw TunnelManagementError.tunnelAlreadyExistsWithThatName
        }

        let provider = providerFactory.makeProvider()
        provider.localizedDescription = name
        // Deliberately saved disabled: iOS keeps a single enabled VPN
        // configuration per app, so enabling a new one here would
        // disable — and disconnect — a currently running tunnel.
        // Activation enables the manager right before it starts.

        do {
            try provider.configure(with: config)
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnAddTunnel(systemError: error)
        }

        activateOnDemand.apply(on: provider)

        do {
            try await provider.savePreferences()
            try await provider.loadPreferences()
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnAddTunnel(systemError: error)
        }

        // The save above already fired `NEVPNConfigurationChange`, and
        // `reload()` can win the race during the awaits — putting its
        // own container for this configuration into the list first.
        // Appending unconditionally would then duplicate the ForEach
        // identity ("ID occurs multiple times").
        if let existing = tunnels.first(where: { $0.id == config.id }) {
            return existing
        }

        let tunnel = TunnelContainer(tunnel: provider)
        tunnels.append(tunnel)
        tunnels = Self.sortedByCreatedAt(tunnels)
        return tunnel
    }

    func modify(tunnel: TunnelContainer, with config: TunnelConfig,
                onDemand: ActivateOnDemandOption) async throws {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TunnelManagementError.tunnelInvalidName
        }
        if tunnels.contains(where: {
            $0.id != tunnel.id
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            throw TunnelManagementError.tunnelAlreadyExistsWithThatName
        }

        tunnel.tunnelProvider.localizedDescription = name
        // `isEnabled` is left untouched for the same reason as in
        // `add`: flipping it on while another tunnel runs would tear
        // that session down. Edits require an inactive tunnel, and
        // activation enables the manager itself.

        do {
            try tunnel.tunnelProvider.configure(with: config)
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnModifyTunnel(systemError: error)
        }

        onDemand.apply(on: tunnel.tunnelProvider)

        do {
            try await tunnel.tunnelProvider.savePreferences()
            try await tunnel.tunnelProvider.loadPreferences()
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnModifyTunnel(systemError: error)
        }

        tunnel.name = name
    }

    func remove(tunnel: TunnelContainer) async throws {
        // Destroy config from Keychain (if underlying provider supports it)
        if let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol {
            proto.destroyConfigInKeychain()
        }

        do {
            try await tunnel.tunnelProvider.removePreferences()
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnRemoveTunnel(systemError: error)
        }

        if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            tunnels.remove(at: index)
        }

        if waitingTunnel?.id == tunnel.id {
            waitingTunnel = nil
        }
    }

    // MARK: - Activation

    func startActivation(of tunnel: TunnelContainer) {
        guard tunnel.status == .inactive else { return }

        // If another tunnel is already active, queue this one as waiting
        if let activeTunnel = tunnels.first(where: { $0.status != .inactive && $0.status != .waiting }) {
            // Reset previous waiting tunnel if any
            if let previousWaiting = waitingTunnel, previousWaiting.id != tunnel.id {
                previousWaiting.status = .inactive
            }
            tunnel.status = .waiting
            waitingTunnel = tunnel
            startDeactivation(of: activeTunnel)
            return
        }

        // Disable on-demand on all other tunnels before activating
        tunnels.filter { $0.id != tunnel.id && $0.isActivateOnDemandEnabled }.forEach { other in
            other.tunnelProvider.isOnDemandEnabled = false
            other.tunnelProvider.savePreferences { _ in }
        }

        startActivation(of: tunnel, at: 0)
    }

    func startDeactivation(of tunnel: TunnelContainer) {
        guard tunnel.status != .inactive && tunnel.status != .deactivating else { return }

        // Disable on-demand first, otherwise system will reconnect
        if tunnel.isActivateOnDemandEnabled {
            tunnel.tunnelProvider.isOnDemandEnabled = false
            Task {
                do {
                    try await tunnel.tunnelProvider.savePreferences()
                    performDeactivation(of: tunnel)
                } catch {
                    // Save failed, skip deactivation
                }
            }
        } else {
            performDeactivation(of: tunnel)
        }
    }

    // MARK: - Private Activation

    private func startActivation(of tunnel: TunnelContainer, at retryIndex: Int) {
        guard retryIndex < maxRetries else {
            tunnel.isAttemptingActivation = false
            tunnel.activationTask?.cancel()
            tunnel.activationTask = nil
            tunnel.status = .inactive
            // Every attempt started without throwing and the system
            // never reported connected or disconnected — there is no
            // system error to show, only the timeout itself.
            tunnel.lastActivationError = .retryLimitReached(
                lastSystemError: Self.noSystemDetail(LocalizationManager.shared.t("error_detail_timeout")))
            return
        }

        if retryIndex == 0 {
            tunnel.status = .activating
            tunnel.lastActivationError = nil
        }

        tunnel.isAttemptingActivation = true
        let attemptId = UUID().uuidString
        tunnel.activationAttemptId = attemptId

        // Ensure manager is enabled and save
        tunnel.tunnelProvider.isEnabled = true
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

    private func doStartVPNTunnel(tunnel: TunnelContainer, attemptId: String, retryIndex: Int) async {
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

        // Start retry task
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

    private func performDeactivation(of tunnel: TunnelContainer) {
        tunnel.status = .deactivating
        tunnel.tunnelProvider.stopTunnel()
    }

    /// Stand-in for the rare paths where the system hands us no error
    /// object; carries a localized description so the alert's `%@`
    /// slot stays honest instead of printing a fabricated code.
    private static func noSystemDetail(_ description: String) -> NSError {
        NSError(
            domain: "PhantomWG",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    private func activateWaitingTunnelIfNeeded() {
        guard let waitingTunnel else { return }
        self.waitingTunnel = nil

        // Verify the waiting tunnel is still in waiting state
        guard waitingTunnel.status == .waiting else { return }

        startActivation(of: waitingTunnel, at: 0)
    }

    // MARK: - Status Observation

    private func startObservingTunnelStatuses() {
        statusObservationToken = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let tunnel = self.tunnels.first(where: { $0.tunnelProvider.matchesNotification(notification) })
                else { return }
                self.handleStatusChange(for: tunnel)
            }
        }
    }

    private func handleStatusChange(for tunnel: TunnelContainer) {
        let systemStatus = tunnel.tunnelProvider.connectionStatus

        // If we're attempting activation, interpret the status in that context
        if tunnel.isAttemptingActivation {
            switch systemStatus {
            case .connected:
                tunnel.isAttemptingActivation = false
                tunnel.activationTask?.cancel()
                tunnel.activationTask = nil
                tunnel.status = .active

            case .disconnected:
                tunnel.isAttemptingActivation = false
                tunnel.activationTask?.cancel()
                tunnel.activationTask = nil
                tunnel.status = .inactive

                if tunnel.lastActivationError == nil {
                    // The system dropped the session mid-activation.
                    // Its own record of why — the extension's start
                    // failure — beats any synthesized stand-in; the
                    // attemptId guard keeps a slow fetch from writing
                    // over a newer activation round.
                    let attemptId = tunnel.activationAttemptId
                    Task { @MainActor in
                        let systemError = await tunnel.tunnelProvider.fetchLastDisconnectError()
                        guard tunnel.activationAttemptId == attemptId,
                              tunnel.lastActivationError == nil else { return }
                        tunnel.lastActivationError = .failedWhileActivating(
                            systemError: systemError
                                ?? Self.noSystemDetail(LocalizationManager.shared.t("error_detail_session_ended")))
                    }
                }

            case .connecting:
                tunnel.status = .activating

            case .disconnecting:
                tunnel.status = .deactivating

            case .reasserting:
                tunnel.status = .reasserting

            default:
                break
            }
        } else {
            // Normal status tracking
            let newStatus = TunnelStatus(from: systemStatus)
            tunnel.status = newStatus

            if newStatus == .inactive {
                activateWaitingTunnelIfNeeded()
            }
        }
    }

    // MARK: - Configuration Observation

    private func startObservingTunnelConfigurations() {
        configObservationToken = NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.reload()
            }
        }
    }

    private func reload() async {
        guard let providers = try? await providerFactory.loadAllFromPreferences() else { return }

        // Update existing tunnels, add new ones, remove deleted ones.
        // Matching goes by persisted identity, not manager instance —
        // `loadAllFromPreferences` hands back fresh objects every call,
        // and an instance comparison would discard the containers the
        // views are already holding (and race `add` into duplicates).
        var newTunnels: [TunnelContainer] = []

        for provider in providers {
            if let existing = tunnels.first(where: { $0.id == provider.tunnelConfig?.id }) {
                existing.name = provider.localizedDescription ?? ""
                existing.refreshStatus()
                newTunnels.append(existing)
            } else {
                newTunnels.append(TunnelContainer(tunnel: provider))
            }
        }

        tunnels = Self.sortedByCreatedAt(newTunnels)
    }
}
