import Foundation
import NetworkExtension

/// In-memory `TunnelProviding` used by SwiftUI previews. Holds its
/// `TunnelConfig` directly, resolves every persistence call
/// synchronously, and walks `connectionStatus` through realistic
/// transitions (`.connecting` → `.connected` …) when the canvas
/// flips a toggle — posting `NEVPNStatusDidChange` with itself as the
/// notification object so `TunnelsManager`'s production observer
/// drives `TunnelContainer` exactly as it does for the real system.
///
/// Provider messages mirror PhantomTunnel's opcode surface:
/// `0` → WireGuard UAPI stats dump, `1` → JSON log entries,
/// `2` → clear log ring, `3` → reset ACK.
final class PreviewTunnelProvider: TunnelProviding {

    /// One extension-side log line, encoded for opcode `1` in the
    /// same shape `LogStore` decodes (`timestamp` / `tag` / `message`).
    struct LogLine: Encodable {
        let timestamp: String
        let tag: String
        let message: String
    }

    // MARK: - TunnelProviding State

    var localizedDescription: String?
    var isEnabled: Bool = true
    var protocolConfiguration: NEVPNProtocol?
    var isOnDemandEnabled: Bool = false
    var onDemandRules: [NEOnDemandRule]?

    private(set) var config: TunnelConfig?
    var tunnelConfig: TunnelConfig? { config }

    private(set) var connectionStatus: NEVPNStatus

    // MARK: - Canned Telemetry

    private var logLines: [LogLine]
    private var rxBytes: Int64 = 47_316_992
    private var txBytes: Int64 = 9_218_048

    /// Invalidates in-flight status transitions when the canvas
    /// toggles faster than the simulated connect/disconnect delay.
    private var transitionID = UUID()

    init(
        config: TunnelConfig?,
        status: NEVPNStatus = .disconnected,
        logLines: [LogLine] = []
    ) {
        self.config = config
        self.connectionStatus = status
        self.logLines = logLines
        self.localizedDescription = config?.name
    }

    // MARK: - Configuration

    /// Production seals the config into the Keychain and keeps only a
    /// persistent reference; the preview provider just keeps the value.
    func configure(with config: TunnelConfig) throws {
        self.config = config
        localizedDescription = config.name
    }

    // MARK: - VPN Control

    func startTunnel() throws {
        transition(to: .connecting)
        scheduleTransition(to: .connected, after: 0.8)
    }

    func stopTunnel() {
        transition(to: .disconnecting)
        scheduleTransition(to: .disconnected, after: 0.4)
    }

    func sendProviderMessage(_ data: Data, responseHandler: @escaping @Sendable (Data?) -> Void) throws {
        switch data.first {
        case 0:
            responseHandler(statsDump().data(using: .utf8))
        case 1:
            responseHandler(try? JSONEncoder().encode(logLines))
        case 2:
            logLines.removeAll()
            responseHandler(Data())
        case 3:
            responseHandler(Data())
        default:
            responseHandler(nil)
        }
    }

    // MARK: - Persistence (synchronous no-ops)

    func savePreferences(completion: @escaping @Sendable (Error?) -> Void) {
        completion(nil)
    }

    func loadPreferences(completion: @escaping @Sendable (Error?) -> Void) {
        completion(nil)
    }

    func removePreferences(completion: @escaping @Sendable (Error?) -> Void) {
        completion(nil)
    }

    // MARK: - Notification Matching

    func matchesNotification(_ notification: Notification) -> Bool {
        (notification.object as? PreviewTunnelProvider) === self
    }

    // MARK: - Equality

    func isEqual(to other: TunnelProviding) -> Bool {
        (other as? PreviewTunnelProvider) === self
    }

    // MARK: - Status Simulation

    private func transition(to status: NEVPNStatus) {
        transitionID = UUID()
        connectionStatus = status
        NotificationCenter.default.post(name: .NEVPNStatusDidChange, object: self)
    }

    private func scheduleTransition(to status: NEVPNStatus, after delay: TimeInterval) {
        let expected = transitionID
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.transitionID == expected else { return }
            self.connectionStatus = status
            NotificationCenter.default.post(name: .NEVPNStatusDidChange, object: self)
        }
    }

    /// WireGuard UAPI-style dump consumed by `StatsFormatter.parse`.
    /// Counters advance a little on every poll so the canvas shows
    /// live-moving transfer numbers; the handshake stays ~12s old.
    private func statsDump() -> String {
        rxBytes += 18_432
        txBytes += 6_144
        let handshake = Int64(Date().timeIntervalSince1970) - 12
        return "rx_bytes=\(rxBytes)\ntx_bytes=\(txBytes)\nlast_handshake_time_sec=\(handshake)"
    }
}

// MARK: - Factory

/// `TunnelProviderFactory` counterpart for previews: hands
/// `TunnelsManager` a canned provider list and mints fresh in-memory
/// providers for the add-tunnel flow, so import works in the canvas.
struct PreviewTunnelProviderFactory: TunnelProviderFactory {

    var providers: [PreviewTunnelProvider]

    init(providers: [PreviewTunnelProvider] = []) {
        self.providers = providers
    }

    func makeProvider() -> TunnelProviding {
        PreviewTunnelProvider(config: nil)
    }

    func loadAllFromPreferences() async throws -> [TunnelProviding] {
        providers
    }
}
