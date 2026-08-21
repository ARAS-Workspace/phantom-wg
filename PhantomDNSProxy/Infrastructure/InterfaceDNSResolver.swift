import Foundation
import SystemConfiguration

enum InterfaceDNSResolver {

    static func dnsServers(for interfaceName: String) -> [String] {
        guard let store = SCDynamicStoreCreate(
            nil,
            "com.remrearas.Phantom-WG-MacOS.InterfaceDNSResolver" as CFString,
            nil,
            nil
        ) else { return [] }

        guard let serviceID = activeServiceID(
            store: store,
            interfaceName: interfaceName
        ) else {
            return []
        }

        let setupKey = "Setup:/Network/Service/\(serviceID)/DNS" as CFString
        if let dns = SCDynamicStoreCopyValue(store, setupKey) as? [String: Any],
           let servers = dns["ServerAddresses"] as? [String],
           !servers.isEmpty {
            return servers
        }

        let stateKey = "State:/Network/Service/\(serviceID)/DNS" as CFString
        if let dns = SCDynamicStoreCopyValue(store, stateKey) as? [String: Any],
           let servers = dns["ServerAddresses"] as? [String],
           !servers.isEmpty {
            return servers
        }

        return []
    }

    static func globalResolverServers() -> [String] {
        guard let store = SCDynamicStoreCreate(
            nil,
            "com.remrearas.Phantom-WG-MacOS.InterfaceDNSResolver.global" as CFString,
            nil,
            nil
        ) else { return [] }

        guard let dns = SCDynamicStoreCopyValue(
            store,
            "State:/Network/Global/DNS" as CFString
        ) as? [String: Any],
              let servers = dns["ServerAddresses"] as? [String] else {
            return []
        }
        return servers
    }

    // MARK: - Private

    private static func activeServiceID(
        store: SCDynamicStore,
        interfaceName: String
    ) -> String? {
        for family in ["IPv4", "IPv6"] {
            let pattern = "State:/Network/Service/[^/]+/\(family)" as CFString
            guard let keys = SCDynamicStoreCopyKeyList(store, pattern) as? [String] else {
                continue
            }

            for key in keys {
                guard
                    let info = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                    let bsdName = info["InterfaceName"] as? String,
                    bsdName == interfaceName,
                    let addresses = info["Addresses"] as? [String],
                    !addresses.isEmpty
                else { continue }

                return key
                    .replacingOccurrences(of: "State:/Network/Service/", with: "")
                    .replacingOccurrences(of: "/\(family)", with: "")
            }
        }
        return nil
    }
}
