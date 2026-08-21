import NetworkExtension

protocol TunnelProviding: AnyObject {

    // MARK: - Identity

    var localizedDescription: String? { get set }
    var isEnabled: Bool { get set }

    // MARK: - Configuration

    var tunnelIdentity: TunnelIdentity? { get }
    func configure(with identity: TunnelIdentity)

    // MARK: - Recovery (NE on-demand)

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

    func matchesNotification(_ notification: Notification) -> Bool

    // MARK: - Diagnostics

    func fetchLastDisconnectError(completion: @escaping @Sendable (Error?) -> Void)
}

// MARK: - Async Wrappers (default implementations wrapping the callback-based methods)

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
