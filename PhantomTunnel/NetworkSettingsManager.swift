import NetworkExtension

enum NetworkSettingsManager {

    /// Applies excluded routes for wstunnel server IPs (prevents routing loop)
    /// and enables IPv6 kill switch (routes all IPv6 into tunnel where it's blackholed).
    static func apply(to settings: NEPacketTunnelNetworkSettings, excludedIPs: [String]) {
        // 1. Excluded route for wstunnel server (prevent routing loop)
        if let ipv4Settings = settings.ipv4Settings {
            var excluded = ipv4Settings.excludedRoutes ?? []
            for ip in excludedIPs {
                excluded.append(NEIPv4Route(destinationAddress: ip, subnetMask: "255.255.255.255"))
                SharedLogger.log(.tunnel, "Excluded route: \(ip)/32")
            }
            ipv4Settings.excludedRoutes = excluded
        }

        // 2. Kill IPv6: route ALL IPv6 into tunnel where it gets dropped
        //    WireGuard is IPv4-only so IPv6 packets are blackholed = no leak
        let ipv6 = NEIPv6Settings(addresses: ["fd00::1"], networkPrefixLengths: [128])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        ipv6.excludedRoutes = []
        settings.ipv6Settings = ipv6
        SharedLogger.log(.tunnel, "IPv6 kill switch active (all IPv6 \u{2192} blackhole)")
    }
}
