import NetworkExtension
import WireGuardKit

class PacketTunnelProvider: NEPacketTunnelProvider {

    private lazy var adapter: WireGuardAdapter = {
        WireGuardAdapter(with: self) { logLevel, message in
            wg_log(logLevel.osLogLevel, message: message)
        }
    }()

    /// Resolved wstunnel server IPv4 addresses (for excluded routes)
    private var wstunnelServerIPv4: [String] = []

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        SharedLogger.log(.tunnel, "PacketTunnelProvider starting...")

        // 1. Decode config
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.tunnelConfig else {
            SharedLogger.log(.tunnel, "ERROR: Invalid tunnel configuration")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }
        SharedLogger.currentTunnelId = config.id.uuidString
        SharedLogger.log(.tunnel, "Config loaded: \(config.name)")

        // 2. Resolve wstunnel server BEFORE starting tunnel (while DNS still works)
        if let host = URL(string: config.wstunnel.url)?.host {
            wstunnelServerIPv4 = DNSResolver.resolveIPv4(host)
            SharedLogger.log(.tunnel, "Wstunnel server resolved: \(host) \u{2192} \(wstunnelServerIPv4)")
        }

        // 3. Start wstunnel (creates local UDP proxy)
        try WstunnelLifecycle.start(config: config.wstunnel)

        // 4. Build WireGuard config (IPv4 only, endpoint → 127.0.0.1:localPort)
        SharedLogger.log(.wireGuard, "Building WireGuard config...")
        let tunnelConfiguration = try WireGuardConfigBuilder.build(from: config)

        // 5. Start WireGuard adapter
        SharedLogger.log(.wireGuard, "Starting WireGuard adapter...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            adapter.start(tunnelConfiguration: tunnelConfiguration) { error in
                if let error {
                    SharedLogger.log(.wireGuard, "ERROR: \(error.localizedDescription)")
                    continuation.resume(throwing: PacketTunnelProviderError.couldNotStartWireGuard)
                } else {
                    continuation.resume()
                }
            }
        }

        SharedLogger.log(.tunnel, "Tunnel active")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        SharedLogger.log(.tunnel, "Stopping tunnel (reason: \(reason.rawValue))")

        // Stop WireGuard first
        SharedLogger.log(.wireGuard, "Stopping WireGuard adapter...")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            adapter.stop { _ in continuation.resume() }
        }
        SharedLogger.log(.wireGuard, "WireGuard stopped")

        // Then stop wstunnel
        WstunnelLifecycle.stop()

        SharedLogger.log(.tunnel, "Tunnel disconnected")
    }

    // MARK: - App Message (runtime stats)

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler else { return }

        if messageData.count == 1 && messageData[0] == 0 {
            adapter.getRuntimeConfiguration { config in
                completionHandler(config?.data(using: .utf8))
            }
        } else {
            completionHandler(nil)
        }
    }

    // MARK: - Network Settings Override

    override func setTunnelNetworkSettings(_ tunnelNetworkSettings: NETunnelNetworkSettings?,
                                           completionHandler: ((Error?) -> Void)? = nil) {
        if let settings = tunnelNetworkSettings as? NEPacketTunnelNetworkSettings {
            NetworkSettingsManager.apply(to: settings, excludedIPs: wstunnelServerIPv4)
        }

        super.setTunnelNetworkSettings(tunnelNetworkSettings, completionHandler: completionHandler)
    }
}
