import Foundation
import NetworkExtension

/// Wraps `NETransparentProxyManager`. Owns the preference entry
/// lifecycle and mirrors the session's `NEVPNStatus`; runtime config
/// and log RPCs go through `SplitTunnelDaemonClient` instead.
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

    /// Finds the existing preference entry, or falls back to a fresh
    /// in-memory manager — the entry itself is first persisted by
    /// `enable()`'s save. Production caller is the session
    /// coordinator's `boot(with:)`.
    func load() async {
        do {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            manager = managers.first ?? NETransparentProxyManager()
            attachStatusObserver()
            refreshSessionStatus()
        } catch {
            // load is non-fatal — the next boot()/start() pass retries.
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

        if let data = try? JSONEncoder().encode(configuration) {
            proto.providerConfiguration = ["split_config": data]
        }

        manager.protocolConfiguration = proto
        manager.localizedDescription = Self.localizedDescription
        manager.isEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        try manager.connection.startVPNTunnel()
    }

    func disable() async throws {
        guard let manager else { return }
        manager.connection.stopVPNTunnel()
        manager.isEnabled = false
        try? await manager.saveToPreferences()
    }

    // MARK: - Remove

    /// Deletes the preference entry entirely — the uninstall path's
    /// counterpart to `enable()`'s save. Loads first when needed so a
    /// cold call still finds the entry. Best-effort: a failure leaves
    /// an entry the uninstall copy already tells the user to remove.
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

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Split-tunnel provider manager not loaded."
            }
        }
    }
}
