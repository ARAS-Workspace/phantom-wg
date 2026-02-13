import Foundation
import NetworkExtension

@MainActor
class TunnelsManager: ObservableObject {

    @Published var tunnels: [TunnelContainer] = []

    private let providerFactory: TunnelProviderFactory
    private var statusObservationToken: AnyObject?
    private var configObservationToken: AnyObject?
    private var waitingTunnel: TunnelContainer?

    // Activation parameters (overridable for tests)
    var retryInterval: TimeInterval = 5.0
    var maxRetries: Int = 8

    // MARK: - Factory

    static func create() async throws -> TunnelsManager {
        let factory = RealTunnelProviderFactory()
        let providers = try await factory.loadAllFromPreferences()
        return TunnelsManager(tunnelProviders: providers, providerFactory: factory)
    }

    init(tunnelProviders: [TunnelProviding], providerFactory: TunnelProviderFactory = RealTunnelProviderFactory()) {
        self.providerFactory = providerFactory
        tunnels = tunnelProviders.map { TunnelContainer(tunnel: $0) }
        startObservingTunnelStatuses()
        startObservingTunnelConfigurations()
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
        if tunnels.contains(where: { $0.name == name }) {
            throw TunnelManagementError.tunnelAlreadyExistsWithThatName
        }

        let provider = providerFactory.makeProvider()
        provider.localizedDescription = name
        provider.isEnabled = true

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

        let tunnel = TunnelContainer(tunnel: provider)
        tunnels.append(tunnel)
        return tunnel
    }

    func modify(tunnel: TunnelContainer, with config: TunnelConfig,
                onDemand: ActivateOnDemandOption) async throws {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TunnelManagementError.tunnelInvalidName
        }
        if tunnels.contains(where: { $0.name == name && $0.id != tunnel.id }) {
            throw TunnelManagementError.tunnelAlreadyExistsWithThatName
        }

        tunnel.tunnelProvider.localizedDescription = name
        tunnel.tunnelProvider.isEnabled = true

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

    func refreshStatuses() {
        tunnels.forEach { $0.refreshStatus() }
    }

    // MARK: - Private Activation

    private func startActivation(of tunnel: TunnelContainer, at retryIndex: Int) {
        guard retryIndex < maxRetries else {
            tunnel.isAttemptingActivation = false
            tunnel.activationTask?.cancel()
            tunnel.activationTask = nil
            tunnel.status = .inactive
            tunnel.lastActivationError = .retryLimitReached(
                lastSystemError: NSError(domain: NEVPNErrorDomain, code: 1))
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

        // Notify parent observers (e.g. TunnelListView) so computed
        // properties like hasActiveTunnel update instantly.
        objectWillChange.send()

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
                    tunnel.lastActivationError = .failedWhileActivating(
                        systemError: NSError(domain: NEVPNErrorDomain, code: 0))
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
                let onDeactivated = tunnel.onDeactivated
                tunnel.onDeactivated = nil
                onDeactivated?(tunnel)

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

        // Update existing tunnels, add new ones, remove deleted ones
        var newTunnels: [TunnelContainer] = []

        for provider in providers {
            if let existing = tunnels.first(where: { $0.tunnelProvider.isEqual(to: provider) }) {
                existing.name = provider.localizedDescription ?? ""
                existing.refreshStatus()
                newTunnels.append(existing)
            } else {
                newTunnels.append(TunnelContainer(tunnel: provider))
            }
        }

        tunnels = newTunnels
    }
}
