import NetworkExtension

extension NETunnelProviderProtocol {

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
