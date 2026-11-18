import NetworkExtension

extension NETunnelProviderProtocol {

    /// The persistent reference of the Keychain item this protocol opens.
    var keychainReference: Data? {
        providerConfiguration?["keychainRef"] as? Data
    }

    /// Read config from Keychain via persistent reference stored in providerConfiguration.
    var tunnelConfig: TunnelConfig? {
        guard let keychainRef = keychainReference,
              let jsonString = Keychain.openReference(called: keychainRef),
              let jsonData = jsonString.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(TunnelConfig.self, from: jsonData)
    }

    /// Create protocol and store config in a new Keychain item. providerConfiguration
    /// holds only the persistent reference — private keys never leave the Keychain.
    /// The item an earlier protocol references is left to the caller.
    /// @witness TunnelEdit.aRefusedSaveLeavesTheSavedTunnelReadable
    convenience init?(tunnelConfig config: TunnelConfig) {
        self.init()

        guard let jsonData = try? JSONEncoder().encode(config),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        guard let newRef = Keychain.makeReference(
            containing: jsonString,
            called: config.id.uuidString
        ) else {
            return nil
        }

        providerBundleIdentifier = "com.artek.Phantom-WG.PhantomTunnel"
        providerConfiguration = ["keychainRef": newRef]
        // Ghost carries the wstunnel URL; a validated standalone config
        // always carries its endpoint, so the chain never lands on nil.
        serverAddress = config.wstunnel?.url.textual ?? config.wireguard.peer.endpoint?.textual
    }

    /// Delete the config data from Keychain when tunnel is removed.
    func destroyConfigInKeychain() {
        guard let ref = keychainReference else { return }
        Keychain.deleteReference(called: ref)
    }
}
