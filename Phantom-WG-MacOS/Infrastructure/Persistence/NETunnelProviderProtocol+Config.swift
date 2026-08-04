import NetworkExtension

extension NETunnelProviderProtocol {

    /// Reads the tunnel's identity out of `providerConfiguration`.
    /// This store is world-readable (`/Library/Preferences/
    /// com.apple.networkextension.plist` is mode 644), which is why it
    /// holds identity only — the secrets live in the vault the tunnel
    /// extension keeps in the System keychain, keyed by `configId`.
    var tunnelIdentity: TunnelIdentity? {
        guard let configId = providerConfiguration?["configId"] as? String,
              let id = UUID(uuidString: configId),
              let name = providerConfiguration?["name"] as? String else {
            return nil
        }

        return TunnelIdentity(
            id: id,
            name: name,
            createdAt: Self.decodeCreatedAt(providerConfiguration?["createdAt"]),
            isGhost: providerConfiguration?["isGhost"] as? Bool ?? false
        )
    }

    /// Creates the protocol object for a tunnel. Nothing sensitive is
    /// written: `serverAddress` is a fixed label rather than the real
    /// endpoint (it is displayed in System Settings and stored in the
    /// same world-readable plist), and the endpoint itself is part of
    /// the vault payload.
    convenience init(identity: TunnelIdentity) {
        self.init()

        providerBundleIdentifier = "com.remrearas.Phantom-WG-MacOS.PhantomTunnel"
        serverAddress = "Phantom-WG"

        providerConfiguration = [
            "configId": identity.id.uuidString,
            "name": identity.name,
            "createdAt": identity.createdAt.timeIntervalSince1970,
            "isGhost": identity.isGhost
        ]
    }

    // MARK: - Helpers

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
