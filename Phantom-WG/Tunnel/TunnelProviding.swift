import NetworkExtension

/// Abstracts NETunnelProviderManager for testability.
/// This is the system boundary: everything inside the app uses this protocol;
/// only NETunnelProviderManager (production) and MockTunnelProvider (tests)
/// implement it directly.
protocol TunnelProviding: AnyObject {

    // MARK: - Identity

    var localizedDescription: String? { get set }
    var isEnabled: Bool { get set }

    // MARK: - Configuration

    var protocolConfiguration: NEVPNProtocol? { get set }
    var tunnelConfig: TunnelConfig? { get }
    func configure(with config: TunnelConfig) throws

    // MARK: - On-Demand

    var isOnDemandEnabled: Bool { get set }
    var onDemandRules: [NEOnDemandRule]? { get set }

    // MARK: - Connection

    var connectionStatus: NEVPNStatus { get }

    // MARK: - VPN Control

    func startTunnel() throws
    func stopTunnel()
    func sendProviderMessage(_ data: Data, responseHandler: @escaping @Sendable (Data?) -> Void) throws

    // MARK: - Persistence

    func savePreferences(completion: @escaping @Sendable (Error?) -> Void)
    func loadPreferences(completion: @escaping @Sendable (Error?) -> Void)
    func removePreferences(completion: @escaping @Sendable (Error?) -> Void)

    // MARK: - Notification Matching

    /// Returns true if the given NEVPNStatusDidChange notification originated from this provider.
    func matchesNotification(_ notification: Notification) -> Bool

    // MARK: - Equality

    /// Used by TunnelsManager.reload() to match existing tunnels with reloaded providers.
    func isEqual(to other: TunnelProviding) -> Bool
}

// MARK: - Async Persistence (default implementations wrapping callback-based methods)

extension TunnelProviding {

    func savePreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            savePreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func loadPreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func removePreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            removePreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
