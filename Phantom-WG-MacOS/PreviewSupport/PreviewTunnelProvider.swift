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
    var isOnDemandEnabled: Bool = false
    var onDemandRules: [NEOnDemandRule]?

    private(set) var config: TunnelConfig?
    var tunnelIdentity: TunnelIdentity? { config?.identity }

    private(set) var connectionStatus: NEVPNStatus

    /// When set, `startTunnel` drops the session instead of
    /// connecting and `fetchLastDisconnectError` reports this —
    /// the canvas twin of the system's disconnect record.
    var disconnectError: Error?

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

    /// Production writes identity only — the payload lives in the
    /// vault. The preview provider keeps the whole config so
    /// `PreviewVaultClient` can serve it back.
    func configure(with identity: TunnelIdentity) {
        guard var updated = config else { return }
        updated.name = identity.name
        config = updated
        localizedDescription = identity.name
    }

    // MARK: - VPN Control

    func startTunnel() throws {
        transition(to: .connecting)
        scheduleTransition(to: disconnectError == nil ? .connected : .disconnected, after: 0.8)
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

    // MARK: - Diagnostics

    func fetchLastDisconnectError(completion: @escaping @Sendable (Error?) -> Void) {
        completion(disconnectError)
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

// MARK: - Vault

/// Stands in for the extension's custody service. Previews have no
/// XPC peer, so this serves the fixture providers' configurations
/// straight from memory — the canvas exercises the same async read
/// path the app uses in production.
@Observable
@MainActor
final class PreviewVaultClient: TunnelVaultClient {

    private var payloads: [UUID: TunnelConfig]

    init(configs: [TunnelConfig]) {
        payloads = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, $0) })
        super.init()
    }

    override func store(_ config: TunnelConfig) async -> Bool {
        payloads[config.id] = config
        return true
    }

    /// When set, every `read(id:)` answers with this instead of the
    /// payload map — lets previews stage the unreachable banner.
    var readOverride: Read?

    override func read(id: UUID) async -> Read {
        if let readOverride { return readOverride }
        return payloads[id].map(Read.config) ?? .missing
    }

    override func delete(id: UUID) async -> Bool {
        payloads.removeValue(forKey: id)
        return true
    }

    override func purge() async -> Bool {
        payloads.removeAll()
        return true
    }

    /// What `ping()` answers; `nil` never resolves, so the canvas can
    /// hold the gate's connecting state indefinitely.
    var pingAnswer: Ping? = .ready(payloads: 0, identity: ExtensionIdentity.current)

    override func ping() async -> Ping {
        guard let pingAnswer else {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
            }
            return .unreachable
        }
        return pingAnswer
    }

    override func readAll() async -> ReadAll {
        .configs(Array(payloads.values))
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
