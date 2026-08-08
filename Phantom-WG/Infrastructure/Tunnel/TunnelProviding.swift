import NetworkExtension

/// Abstracts NETunnelProviderManager behind the app's system boundary:
/// everything inside the app talks to this protocol. Production binds it
/// to NETunnelProviderManager; SwiftUI previews bind it to
/// PreviewTunnelProvider so every view renders without NE preferences
/// or the VPN entitlement.
protocol TunnelProviding: AnyObject {

    // MARK: - Identity

    var localizedDescription: String? { get set }
    var isEnabled: Bool { get set }

    // MARK: - Configuration

    var protocolConfiguration: NEVPNProtocol? { get set }
    var tunnelConfig: TunnelConfig? { get }
    func configure(with config: TunnelConfig) throws

    // MARK: - Recovery (NE on-demand)

    /// Storage for the recovery rule — armed on activation, stood
    /// down on deactivation; see `TunnelsManager.armRecovery`.
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

    // MARK: - Diagnostics

    /// The system's record of why the last session ended, when it has
    /// one — the extension's `startTunnel` failure surfaces here.
    func fetchLastDisconnectError(completion: @escaping @Sendable (Error?) -> Void)
}

// MARK: - Async Persistence (default implementations wrapping callback-based methods)

extension TunnelProviding {

    func savePreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            savePreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func loadPreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func removePreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            removePreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func fetchLastDisconnectError() async -> Error? {
        await withCheckedContinuation { continuation in
            fetchLastDisconnectError { continuation.resume(returning: $0) }
        }
    }
}
