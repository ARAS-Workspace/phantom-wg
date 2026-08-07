import NetworkExtension

/// Ghost-mode route carve-out: the wstunnel server's resolved
/// addresses are excluded from the tunnel so the WebSocket carrier
/// rides the physical interface — if its packets entered the tunnel
/// they would loop back into the very transport that carries them.
/// Standalone tunnels need no carve-out and pass through untouched.
enum NetworkSettingsManager {

    static func apply(
        to settings: NEPacketTunnelNetworkSettings,
        excludedIPv4: [String],
        excludedIPv6: [String],
        isGhostMode: Bool
    ) {
        guard isGhostMode else { return }

        if let ipv4Settings = settings.ipv4Settings {
            var excluded = ipv4Settings.excludedRoutes ?? []
            for ip in excludedIPv4 {
                excluded.append(NEIPv4Route(destinationAddress: ip, subnetMask: "255.255.255.255"))
                TunnelLogger.log(.tunnel, "Excluded route: \(ip)/32")
            }
            ipv4Settings.excludedRoutes = excluded
        }

        if let ipv6Settings = settings.ipv6Settings {
            var excluded = ipv6Settings.excludedRoutes ?? []
            for ip in excludedIPv6 {
                excluded.append(NEIPv6Route(destinationAddress: ip, networkPrefixLength: 128))
                TunnelLogger.log(.tunnel, "Excluded route: \(ip)/128")
            }
            ipv6Settings.excludedRoutes = excluded
        }
    }
}
