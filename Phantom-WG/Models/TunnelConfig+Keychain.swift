import NetworkExtension

extension NETunnelProviderProtocol {

    /// Read config from Keychain via persistent reference stored in providerConfiguration.
    var tunnelConfig: TunnelConfig? {
        guard let providerConfig = providerConfiguration,
              let keychainRef = providerConfig["keychainRef"] as? Data,
              let jsonString = Keychain.openReference(called: keychainRef),
              let jsonData = jsonString.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(TunnelConfig.self, from: jsonData)
    }

    /// Create protocol and store config in Keychain. providerConfiguration holds only
    /// the persistent reference — private keys never leave the Keychain.
    convenience init?(tunnelConfig config: TunnelConfig,
                      previouslyFrom proto: NETunnelProviderProtocol? = nil) {
        self.init()

        guard let jsonData = try? JSONEncoder().encode(config),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        // Reuse or replace existing Keychain entry
        let oldRef = proto?.providerConfiguration?["keychainRef"] as? Data
        guard let newRef = Keychain.makeReference(
            containing: jsonString,
            called: config.id.uuidString,
            previouslyReferencedBy: oldRef
        ) else {
            return nil
        }

        providerBundleIdentifier = "com.remrearas.Phantom-WG.PhantomTunnel"
        providerConfiguration = ["keychainRef": newRef]
        serverAddress = config.wstunnel.url
    }

    /// Delete the config data from Keychain when tunnel is removed.
    func destroyConfigInKeychain() {
        guard let ref = providerConfiguration?["keychainRef"] as? Data else { return }
        Keychain.deleteReference(called: ref)
    }
}