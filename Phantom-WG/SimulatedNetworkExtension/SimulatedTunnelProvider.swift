#if DEBUG && targetEnvironment(simulator)
import Foundation
import NetworkExtension

/// A `TunnelProviding` that keeps its data in a real
/// `NETunnelProviderManager` — so `configure(with:)` and `tunnelConfig`
/// run the production Keychain path unchanged — and sends every system
/// call to `SimulatedNetworkExtension` instead of `nehelper`. Like a real
/// manager object, a property change stays on this object until
/// `savePreferences` writes it, and `loadPreferences` reads the stored
/// record back over it.
final class SimulatedTunnelProvider: TunnelProviding {

    private let system: SimulatedNetworkExtension
    private let manager = NETunnelProviderManager()
    private(set) var configurationID: UUID?

    init(system: SimulatedNetworkExtension) {
        self.system = system
    }

    init(system: SimulatedNetworkExtension, record: SimulatedNetworkExtension.Record) {
        self.system = system
        configurationID = record.id
        apply(record)
    }

    // MARK: - Identity and Configuration

    var localizedDescription: String? {
        get { manager.localizedDescription }
        set { manager.localizedDescription = newValue }
    }

    var isEnabled: Bool {
        get { manager.isEnabled }
        set { manager.isEnabled = newValue }
    }

    var protocolConfiguration: NEVPNProtocol? {
        get { manager.protocolConfiguration }
        set { manager.protocolConfiguration = newValue }
    }

    var tunnelConfig: TunnelConfig? {
        manager.tunnelConfig
    }

    func configure(with config: TunnelConfig) throws {
        try manager.configure(with: config)
    }

    var isOnDemandEnabled: Bool {
        get { manager.isOnDemandEnabled }
        set { manager.isOnDemandEnabled = newValue }
    }

    var onDemandRules: [NEOnDemandRule]? {
        get { manager.onDemandRules }
        set { manager.onDemandRules = newValue }
    }

    // MARK: - Connection

    var connectionStatus: NEVPNStatus {
        guard let configurationID else { return .invalid }
        return system.session(for: configurationID).status
    }

    func startTunnel() throws {
        guard let configurationID, let record = system.record(configurationID) else {
            throw NEVPNError(.configurationInvalid)
        }
        guard record.isEnabled else {
            SimulatedNetworkExtension.log.info("start refused, disabled \(SimulatedNetworkExtension.label(record), privacy: .public)")
            throw NEVPNError(.configurationDisabled)
        }
        system.session(for: configurationID).start(
            protocolConfiguration: SimulatedNetworkExtension.protocolConfiguration(of: record)
        )
    }

    func stopTunnel() {
        guard let configurationID else { return }
        system.session(for: configurationID).stop()
    }

    func sendProviderMessage(_ data: Data, responseHandler: @escaping @Sendable (Data?) -> Void) throws {
        guard let configurationID, let process = system.session(for: configurationID).process else {
            throw NSError(
                domain: "SimulatedNetworkExtension",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The simulated extension is not running."]
            )
        }
        process.handleAppMessage(data, completion: responseHandler)
    }

    // MARK: - Persistence

    func savePreferences(completion: @escaping @Sendable (Error?) -> Void) {
        let id = configurationID ?? UUID()
        configurationID = id
        let record = SimulatedNetworkExtension.Record(
            id: id,
            localizedDescription: manager.localizedDescription,
            isEnabled: manager.isEnabled,
            isOnDemandEnabled: manager.isOnDemandEnabled,
            protocolConfiguration: SimulatedNetworkExtension.archived(manager.protocolConfiguration),
            onDemandRules: SimulatedNetworkExtension.archived(manager.onDemandRules.map { $0 as NSArray })
        )
        DispatchQueue.main.async { [system] in
            system.save(record)
            completion(nil)
        }
    }

    func loadPreferences(completion: @escaping @Sendable (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let self, let id = self.configurationID, let record = self.system.record(id) {
                self.apply(record)
            }
            completion(nil)
        }
    }

    func removePreferences(completion: @escaping @Sendable (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let self, let id = self.configurationID {
                self.system.remove(id)
            }
            completion(nil)
        }
    }

    // MARK: - Notification Matching

    func matchesNotification(_ notification: Notification) -> Bool {
        guard let configurationID, let session = notification.object as? SimulatedSession else { return false }
        return session.configurationID == configurationID
    }

    // MARK: - Diagnostics

    func fetchLastDisconnectError(completion: @escaping @Sendable (Error?) -> Void) {
        let error = configurationID.flatMap { system.session(for: $0).lastDisconnectError }
        DispatchQueue.main.async {
            completion(error)
        }
    }

    // MARK: - Private

    private func apply(_ record: SimulatedNetworkExtension.Record) {
        manager.localizedDescription = record.localizedDescription
        manager.isEnabled = record.isEnabled
        manager.isOnDemandEnabled = record.isOnDemandEnabled
        manager.protocolConfiguration = SimulatedNetworkExtension.protocolConfiguration(of: record)
        manager.onDemandRules = SimulatedNetworkExtension.onDemandRules(of: record)
    }
}

/// `TunnelProviderFactory` over `SimulatedNetworkExtension`: loading reads
/// the simulated store, and the first load brings armed configurations
/// back the way on-demand would have kept them.
struct SimulatedTunnelProviderFactory: TunnelProviderFactory {

    var system: SimulatedNetworkExtension = .shared

    func makeProvider() -> TunnelProviding {
        SimulatedTunnelProvider(system: system)
    }

    func loadAllFromPreferences() async throws -> [TunnelProviding] {
        await MainActor.run {
            let providers: [TunnelProviding] = system.records.map {
                SimulatedTunnelProvider(system: system, record: $0)
            }
            DispatchQueue.main.async { [system] in
                system.resumeArmedSessionsOnce()
            }
            return providers
        }
    }
}
#endif
