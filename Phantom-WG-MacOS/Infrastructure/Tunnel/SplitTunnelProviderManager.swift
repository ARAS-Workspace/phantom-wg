import Foundation
import NetworkExtension

@Observable
@MainActor
class SplitTunnelProviderManager {

    enum SessionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case disconnecting
        case invalid
    }

    var sessionStatus: SessionStatus = .disconnected

    @ObservationIgnored private var manager: NETransparentProxyManager?
    @ObservationIgnored private var statusObserver: NSObjectProtocol?

    private static let providerBundleID = "com.remrearas.Phantom-WG-MacOS.PhantomSplitTunnel"
    private static let localizedDescription = "Phantom-WG Split-Tunnel"

    // MARK: - Load

    /// @witness SplitControlPlane.door
    func load() async {
        do {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            manager = managers.first ?? NETransparentProxyManager()
            attachStatusObserver()
            refreshSessionStatus()
        } catch {
        }
    }

    // MARK: - Enable / Disable

    func enable(with configuration: SplitTunnelingConfiguration) async throws {
        guard let manager else {
            throw ManagerError.notLoaded
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = "127.0.0.1"

        guard let data = try? JSONEncoder().encode(configuration) else {
            throw ManagerError.blobNotEncodable
        }
        proto.providerConfiguration = ["split_config": data]

        manager.protocolConfiguration = proto
        manager.localizedDescription = Self.localizedDescription
        manager.isEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        try manager.connection.startVPNTunnel()
    }

    /// @witness SplitControlPlane.door
    /// @witness SplitControlPlane.stopThenEdit
    func persistConfiguration(_ configuration: SplitTunnelingConfiguration) async throws {
        guard let manager else {
            throw ManagerError.notLoaded
        }
        try await manager.loadFromPreferences()
        guard manager.isEnabled else { return }
        guard let data = try? JSONEncoder().encode(configuration) else {
            throw ManagerError.blobNotEncodable
        }

        let existing = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?["split_config"] as? Data
        if existing == data { return }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.providerBundleID
        proto.serverAddress = "127.0.0.1"
        proto.providerConfiguration = ["split_config": data]

        manager.protocolConfiguration = proto
        manager.localizedDescription = Self.localizedDescription
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }

    func disable() async throws {
        guard let manager else { return }
        manager.connection.stopVPNTunnel()
        manager.isEnabled = false
        try await manager.saveToPreferences()
    }

    // MARK: - Remove

    func remove() async {
        if manager == nil { await load() }
        guard let manager else { return }
        try? await manager.removeFromPreferences()
        self.manager = nil
        sessionStatus = .disconnected
    }

    // MARK: - Observation

    private func attachStatusObserver() {
        if let existing = statusObserver {
            NotificationCenter.default.removeObserver(existing)
            statusObserver = nil
        }
        guard let manager else { return }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSessionStatus()
            }
        }
    }

    private func refreshSessionStatus() {
        guard let manager else {
            sessionStatus = .disconnected
            return
        }
        switch manager.connection.status {
        case .connected:     sessionStatus = .connected
        case .connecting, .reasserting: sessionStatus = .connecting
        case .disconnecting: sessionStatus = .disconnecting
        case .disconnected:  sessionStatus = .disconnected
        case .invalid:       sessionStatus = .invalid
        @unknown default:    sessionStatus = .invalid
        }
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Errors

    enum ManagerError: LocalizedError {
        case notLoaded
        case blobNotEncodable

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Split-tunnel provider manager not loaded."
            case .blobNotEncodable:
                return "Split-tunnel configuration could not be encoded."
            }
        }
    }
}
