import Foundation

enum WstunnelLifecycle {

    private static var isStarted = false

    /// Starts the wstunnel local UDP proxy with the given configuration.
    /// The UDP listener binds to `localHost:localPort` — the same pair
    /// Ghost mode builds the WireGuard endpoint from — so the two sides
    /// meet by construction. Fields arrive decoded straight from the
    /// vault payload, not through the draft validator, hence the guard.
    static func start(config: WstunnelConfig) throws {
        guard !config.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            TunnelLogger.log(.wstunnel, "ERROR: empty remoteHost")
            throw PacketTunnelProviderError.invalidWstunnelConfig
        }

        TunnelLogger.log(.wstunnel, "Starting wstunnel...")
        TunnelLogger.log(.wstunnel, "Remote: \(config.url.textual)")
        TunnelLogger.log(.wstunnel, "Local proxy: \(config.localHost):\(config.localPort)")
        TunnelLogger.log(.wstunnel, "Forward to: \(config.remoteHost):\(config.remotePort)")

        WstunnelBridge.setLogCallback { _, message in
            TunnelLogger.log(.wstunnel, message)
        }
        WstunnelBridge.initLogging(level: .info)
        TunnelLogger.log(.wstunnel, "Version: \(WstunnelBridge.version)")

        do {
            let wsConfig = WstunnelBridge.Config()
            try wsConfig.setRemoteURL(config.url.textual)
            try wsConfig.setHTTPUpgradePathPrefix(config.secret)
            try wsConfig.addTunnelUDP(
                localHost: config.localHost,
                localPort: config.localPort,
                remoteHost: config.remoteHost,
                remotePort: config.remotePort
            )
            try wsConfig.start()
            isStarted = true
            TunnelLogger.log(.wstunnel, "Wstunnel started (running: \(WstunnelBridge.isRunning))")
        } catch {
            TunnelLogger.log(.wstunnel, "ERROR: \(error.localizedDescription)")
            if let lastErr = WstunnelBridge.lastError {
                TunnelLogger.log(.wstunnel, "Detail: \(lastErr)")
            }
            throw PacketTunnelProviderError.couldNotStartWstunnel
        }
    }

    /// Stops the wstunnel proxy. Idempotent - safe to call multiple times.
    static func stop() {
        guard isStarted else { return }
        isStarted = false

        TunnelLogger.log(.wstunnel, "Stopping wstunnel...")
        do {
            try WstunnelBridge.stop()
            TunnelLogger.log(.wstunnel, "Wstunnel stopped")
        } catch {
            TunnelLogger.log(.wstunnel, "Stop error: \(error.localizedDescription)")
        }
    }
}
