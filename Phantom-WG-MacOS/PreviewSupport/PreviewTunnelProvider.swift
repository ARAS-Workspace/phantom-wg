import Foundation
import NetworkExtension

final class PreviewTunnelProvider: TunnelProviding {

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

    var disconnectError: Error?

    // MARK: - Canned Telemetry

    private var logLines: [LogLine]
    private var rxBytes: Int64 = 47_316_992
    private var txBytes: Int64 = 9_218_048

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
            responseHandler(Data([3, TunnelResetReply.rebuilt.rawValue]))
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

    private func statsDump() -> String {
        rxBytes += 18_432
        txBytes += 6_144
        let handshake = Int64(Date().timeIntervalSince1970) - 12
        return "rx_bytes=\(rxBytes)\ntx_bytes=\(txBytes)\nlast_handshake_time_sec=\(handshake)"
    }
}

// MARK: - Vault

@Observable
@MainActor
final class PreviewVaultClient: TunnelVaultClient {

    private var payloads: [UUID: TunnelConfig]

    init(configs: [TunnelConfig]) {
        payloads = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, $0) })
        super.init()
    }

    override func store(_ config: TunnelConfig) async -> Write {
        payloads[config.id] = config
        return .done
    }

    var readOverride: Read?

    override func read(id: UUID) async -> Read {
        if let readOverride { return readOverride }
        return payloads[id].map(Read.config) ?? .missing
    }

    override func delete(id: UUID) async -> Write {
        payloads.removeValue(forKey: id)
        return .done
    }

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
