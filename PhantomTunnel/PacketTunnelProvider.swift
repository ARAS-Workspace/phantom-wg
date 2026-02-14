import NetworkExtension
import WireGuardKit
import os.log

private let extLog = OSLog(subsystem: "com.remrearas.Phantom-WG-Mac.PhantomTunnel", category: "tunnel")

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
        os_log("PacketTunnelProvider startTunnel called", log: extLog, type: .default)
        SharedLogger.log(.tunnel, "PacketTunnelProvider starting...")

        // 1. Decode config
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
            os_log("ERROR: protocolConfiguration is not NETunnelProviderProtocol", log: extLog, type: .error)
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }

        guard let config = proto.tunnelConfig else {
            os_log("ERROR: tunnelConfig is nil (Keychain read failed?)", log: extLog, type: .error)
            SharedLogger.log(.tunnel, "ERROR: Invalid tunnel configuration")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }

        SharedLogger.currentTunnelId = config.id.uuidString
        os_log("Config loaded: %{public}@", log: extLog, type: .default, config.name)
        SharedLogger.log(.tunnel, "Config loaded: \(config.name)")

        // 2. Resolve wstunnel server BEFORE starting tunnel (while DNS still works)
        if let host = URL(string: config.wstunnel.url)?.host {
            wstunnelServerIPv4 = DNSResolver.resolveIPv4(host)
            os_log("DNS resolved: %{public}@ → %{public}@", log: extLog, type: .default, host, wstunnelServerIPv4.description)
            SharedLogger.log(.tunnel, "Wstunnel server resolved: \(host) \u{2192} \(wstunnelServerIPv4)")
        }

        // 3. Start wstunnel (creates local UDP proxy)
        os_log("Starting wstunnel...", log: extLog, type: .default)
        do {
            try WstunnelLifecycle.start(config: config.wstunnel)
            os_log("Wstunnel started OK", log: extLog, type: .default)
        } catch {
            os_log("Wstunnel FAILED: %{public}@", log: extLog, type: .error, error.localizedDescription)
            throw error
        }

        // 4. Build WireGuard config (IPv4 only, endpoint → 127.0.0.1:localPort)
        os_log("Building WireGuard config...", log: extLog, type: .default)
        SharedLogger.log(.wireGuard, "Building WireGuard config...")
        let tunnelConfiguration = try WireGuardConfigBuilder.build(from: config)

        // 5. Start WireGuard adapter
        os_log("Starting WireGuard adapter...", log: extLog, type: .default)
        SharedLogger.log(.wireGuard, "Starting WireGuard adapter...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            adapter.start(tunnelConfiguration: tunnelConfiguration) { error in
                if let error {
                    os_log("WireGuard FAILED: %{public}@", log: extLog, type: .error, error.localizedDescription)
                    SharedLogger.log(.wireGuard, "ERROR: \(error.localizedDescription)")
                    continuation.resume(throwing: PacketTunnelProviderError.couldNotStartWireGuard)
                } else {
                    os_log("WireGuard started OK", log: extLog, type: .default)
                    continuation.resume()
                }
            }
        }

        os_log("Tunnel active!", log: extLog, type: .default)
        SharedLogger.log(.tunnel, "Tunnel active")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        os_log("stopTunnel called (reason: %d)", log: extLog, type: .default, reason.rawValue)
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
