import NetworkExtension

extension NETunnelProviderManager: TunnelProviding {

    // MARK: - Connection Status

    var connectionStatus: NEVPNStatus {
        connection.status
    }

    // MARK: - Configuration

    var tunnelConfig: TunnelConfig? {
        (protocolConfiguration as? NETunnelProviderProtocol)?.tunnelConfig
    }

    func configure(with config: TunnelConfig) throws {
        let oldProto = protocolConfiguration as? NETunnelProviderProtocol
        guard let newProto = NETunnelProviderProtocol(tunnelConfig: config, previouslyFrom: oldProto) else {
            throw NSError(domain: "PhantomWG", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create protocol configuration"])
        }
        protocolConfiguration = newProto
    }

    // MARK: - VPN Control

    func startTunnel() throws {
        guard let session = connection as? NETunnelProviderSession else {
            throw NSError(domain: "PhantomWG", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid tunnel session"])
        }
        try session.startVPNTunnel()
    }

    func stopTunnel() {
        connection.stopVPNTunnel()
    }

    func sendProviderMessage(_ data: Data, responseHandler: @escaping @Sendable (Data?) -> Void) throws {
        guard let session = connection as? NETunnelProviderSession else {
            throw NSError(domain: "PhantomWG", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid tunnel session"])
        }
        try session.sendProviderMessage(data, responseHandler: responseHandler)
    }

    // MARK: - Persistence

    func savePreferences(completion: @escaping @Sendable (Error?) -> Void) {
        saveToPreferences(completionHandler: completion)
    }

    func loadPreferences(completion: @escaping @Sendable (Error?) -> Void) {
        loadFromPreferences(completionHandler: completion)
    }

    func removePreferences(completion: @escaping @Sendable (Error?) -> Void) {
        removeFromPreferences(completionHandler: completion)
    }

    // MARK: - Notification Matching

    func matchesNotification(_ notification: Notification) -> Bool {
        guard let session = notification.object as? NETunnelProviderSession else { return false }
        return connection === session
    }

    // MARK: - Equality

    func isEqual(to other: TunnelProviding) -> Bool {
        guard let otherManager = other as? NETunnelProviderManager else { return false }
        return self == otherManager
    }
}
