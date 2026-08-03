import NetworkExtension

extension NETunnelProviderProtocol {

    /// Read config from providerConfiguration. WireGuard and (optional)
    /// Wstunnel sections are stored as separate JSON blobs alongside
    /// identity metadata (id, name, createdAt).
    var tunnelConfig: TunnelConfig? {
        guard let configId = providerConfiguration?["configId"] as? String,
              let id = UUID(uuidString: configId),
              let name = providerConfiguration?["name"] as? String,
              let wgData = providerConfiguration?["wireguardConfig"] as? Data,
              let wireguard = try? JSONDecoder().decode(WireguardConfig.self, from: wgData) else {
            return nil
        }

        let createdAt = Self.decodeCreatedAt(providerConfiguration?["createdAt"])

        var wstunnel: WstunnelConfig?
        if let wsData = providerConfiguration?["wstunnelConfig"] as? Data {
            wstunnel = try? JSONDecoder().decode(WstunnelConfig.self, from: wsData)
        }

        return TunnelConfig(
            id: id,
            name: name,
            createdAt: createdAt,
            wireguard: wireguard,
            wstunnel: wstunnel
        )
    }

    /// Create protocol with config embedded in providerConfiguration.
    convenience init?(tunnelConfig config: TunnelConfig) {
        self.init()

        guard let wgData = try? JSONEncoder().encode(config.wireguard) else { return nil }

        providerBundleIdentifier = "com.remrearas.Phantom-WG-MacOS.PhantomTunnel"

        var providerConfig: [String: Any] = [
            "configId": config.id.uuidString,
            "name": config.name,
            "createdAt": config.createdAt.timeIntervalSince1970,
            "wireguardConfig": wgData
        ]

        if let wstunnel = config.wstunnel,
           let wsData = try? JSONEncoder().encode(wstunnel) {
            providerConfig["wstunnelConfig"] = wsData
        }

        providerConfiguration = providerConfig
        serverAddress = config.wstunnel?.url.textual ?? config.wireguard.peer.endpoint.textual
    }

    // MARK: - Helpers

    /// Accepts either a Double (seconds since 1970, current format) or
    /// a missing field (fallback to "now" for migration safety). Once
    /// the app has been run post-refactor every tunnel persists its
    /// `createdAt` on the next save.
    private static func decodeCreatedAt(_ raw: Any?) -> Date {
        if let seconds = raw as? Double {
            return Date(timeIntervalSince1970: seconds)
        }
        if let number = raw as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        return Date()
    }
}
