import Foundation
import SystemConfiguration

/// Reads the DNS resolver list configured for a specific BSD network
/// interface (e.g. "en0").
///
/// macOS keeps DNS in two places:
///
/// - `Setup:/Network/Service/<id>/DNS` — values the user typed into
///   System Settings. Persistent. Primary source of truth.
/// - `State:/Network/Service/<id>/DNS` — runtime view kept by `configd`,
///   typically reflects DHCP-supplied resolvers when no manual values
///   are set, or merged values when both exist.
///
/// We mirror `scutil --dns`'s precedence: read Setup first, fall back
/// to State, return empty when neither has anything. Active-service
/// filtering is done on the State per-family dictionaries, `IPv4`
/// then `IPv6` (where runtime interface↔service binding lives) —
/// Setup alone wouldn't tell us which service is bound to a given BSD
/// name right now. Both families on purpose: an IPv6-only service has
/// no State `IPv4` entry at all, and reading one family would drop it.
enum InterfaceDNSResolver {

    /// Returns the configured DNS server addresses for `interfaceName`,
    /// or `[]` when no active service binds the interface or the
    /// service has no DNS configured. Strict mode at the call site
    /// turns empty into a flow rejection rather than a silent leak.
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

        // Setup priority — what the user typed in System Settings.
        let setupKey = "Setup:/Network/Service/\(serviceID)/DNS" as CFString
        if let dns = SCDynamicStoreCopyValue(store, setupKey) as? [String: Any],
           let servers = dns["ServerAddresses"] as? [String],
           !servers.isEmpty {
            return servers
        }

        // State fallback — DHCP / runtime-pushed values.
        let stateKey = "State:/Network/Service/\(serviceID)/DNS" as CFString
        if let dns = SCDynamicStoreCopyValue(store, stateKey) as? [String: Any],
           let servers = dns["ServerAddresses"] as? [String],
           !servers.isEmpty {
            return servers
        }

        return []
    }

    /// Returns the OS's global resolver chain — the unscoped default
    /// used by apps when no interface scoping applies. While a tunnel
    /// is up this is typically the tunnel-pushed resolver. Used only
    /// in `DNSProxyProvider`'s passthrough branch (unmatched apps).
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

    /// Finds the active network service ID currently bound to a BSD
    /// interface (e.g. "en0"). A service qualifies as active when it
    /// has at least one address in **either** family — checks IPv4
    /// first, then IPv6, so dual-stack and IPv6-only services are
    /// both covered. Inactive duplicates that share a BSD name don't
    /// hijack the lookup.
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
