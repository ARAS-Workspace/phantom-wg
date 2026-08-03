import Foundation
import NetworkExtension

@Observable
@MainActor
class TunnelsManager {

    var tunnels: [TunnelContainer] = []

    @ObservationIgnored private let providerFactory: TunnelProviderFactory
    @ObservationIgnored private var statusObservationToken: AnyObject?
    @ObservationIgnored private var configObservationToken: AnyObject?
    @ObservationIgnored var waitingTunnel: TunnelContainer?

    // Activation retry pacing (consumed by TunnelsManager+Activation)
    let retryInterval: TimeInterval = 5.0
    let maxRetries: Int = 8

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

    func add(config: TunnelConfig) async throws -> TunnelContainer {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TunnelManagementError.tunnelInvalidName
        }
        if tunnels.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
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

        do {
            try await provider.savePreferences()
            try await provider.loadPreferences()
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnAddTunnel(systemError: error)
        }

        let tunnel = TunnelContainer(tunnel: provider)
        tunnels.append(tunnel)
        tunnels = Self.sortedByCreatedAt(tunnels)
        return tunnel
    }

    func modify(tunnel: TunnelContainer, with config: TunnelConfig) async throws {
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
        tunnel.tunnelProvider.isEnabled = true

        do {
            try tunnel.tunnelProvider.configure(with: config)
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnModifyTunnel(systemError: error)
        }

        do {
            try await tunnel.tunnelProvider.savePreferences()
            try await tunnel.tunnelProvider.loadPreferences()
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnModifyTunnel(systemError: error)
        }

        tunnel.name = name
    }

    func remove(tunnel: TunnelContainer) async throws {
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

    /// Deactivate any active tunnel and remove all VPN configurations.
    /// Used during full uninstall. Errors on individual tunnels are
    /// collected and the first one is thrown at the end — partial
    /// cleanup is preferred over abort on first failure.
    func removeAll() async throws {
        for tunnel in tunnels where tunnel.status != .inactive {
            startDeactivation(of: tunnel)
        }

        var firstError: Error?
        for tunnel in tunnels {
            do {
                try await tunnel.tunnelProvider.removePreferences()
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        tunnels.removeAll()
        waitingTunnel = nil

        if let firstError {
            throw TunnelManagementError.vpnSystemErrorOnRemoveTunnel(systemError: firstError)
        }
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
            let newStatus = TunnelStatus(from: systemStatus)
            tunnel.status = newStatus

            if newStatus == .inactive {
                let onDeactivated = tunnel.onDeactivated
                tunnel.onDeactivated = nil
                onDeactivated?(tunnel)

                activateWaitingTunnelIfNeeded()
            }
        }

        let isActive = tunnels.contains { $0.status == .active }
        NotificationCenter.default.post(
            name: NSNotification.Name("PhantomTunnelStatusChanged"),
            object: nil,
            userInfo: ["isActive": isActive]
        )
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

        tunnels = Self.sortedByCreatedAt(newTunnels)
    }
}
