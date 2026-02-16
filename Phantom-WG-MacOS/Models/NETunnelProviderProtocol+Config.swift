import NetworkExtension

extension NETunnelProviderProtocol {

    /// Read config from embedded JSON in providerConfiguration.
    var tunnelConfig: TunnelConfig? {
        guard let data = providerConfiguration?["configData"] as? Data else { return nil }
        return try? JSONDecoder().decode(TunnelConfig.self, from: data)
    }

    /// Create protocol with config embedded in providerConfiguration.
    /// Also persists to ConfigStore for app-side listing.
    convenience init?(tunnelConfig config: TunnelConfig,
                      previouslyFrom proto: NETunnelProviderProtocol? = nil) {
        self.init()

        guard let jsonData = try? JSONEncoder().encode(config) else { return nil }

        // Clean up old config from ConfigStore if ID changed
        if let oldId = proto?.providerConfiguration?["configId"] as? String,
           oldId != config.id.uuidString {
            ConfigStore.delete(idString: oldId)
        }

        // Persist to ConfigStore (app-side listing/editing)
        ConfigStore.save(config)

        providerBundleIdentifier = "com.remrearas.Phantom-WG-MacOS.PhantomTunnel"
        providerConfiguration = [
            "configId": config.id.uuidString,
            "configData": jsonData
        ]
        serverAddress = config.wstunnel.url
    }

    /// Delete config from ConfigStore when tunnel is removed.
    func destroyConfig() {
        guard let configId = providerConfiguration?["configId"] as? String else { return }
        ConfigStore.delete(idString: configId)
    }
}
