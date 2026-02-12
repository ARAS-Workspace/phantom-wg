import Foundation

enum WstunnelLifecycle {

    /// Starts the wstunnel local UDP proxy with the given configuration.
    /// Logs progress and errors via SharedLogger.
    static func start(config: WstunnelConfig) throws {
        SharedLogger.log(.wstunnel, "Starting wstunnel...")
        SharedLogger.log(.wstunnel, "Remote: \(config.url)")
        SharedLogger.log(.wstunnel, "Local proxy: 127.0.0.1:\(config.localPort)")
        SharedLogger.log(.wstunnel, "Forward to: \(config.remoteHost):\(config.remotePort)")

        WstunnelBridge.setLogCallback { _, message in
            SharedLogger.log(.wstunnel, message)
        }
        WstunnelBridge.initLogging(level: .info)
        SharedLogger.log(.wstunnel, "Version: \(WstunnelBridge.version)")

        do {
            let wsConfig = WstunnelBridge.Config()
            try wsConfig.setRemoteURL(config.url)
            try wsConfig.setHTTPUpgradePathPrefix(config.secret)
            try wsConfig.addTunnelUDP(
                localPort: config.localPort,
                remoteHost: config.remoteHost,
                remotePort: config.remotePort
            )
            try wsConfig.start()
            SharedLogger.log(.wstunnel, "Wstunnel started (running: \(WstunnelBridge.isRunning))")
        } catch {
            SharedLogger.log(.wstunnel, "ERROR: \(error.localizedDescription)")
            if let lastErr = WstunnelBridge.lastError {
                SharedLogger.log(.wstunnel, "Detail: \(lastErr)")
            }
            throw PacketTunnelProviderError.couldNotStartWstunnel
        }
    }

    /// Stops the wstunnel proxy. Logs any errors but does not throw.
    static func stop() {
        SharedLogger.log(.wstunnel, "Stopping wstunnel...")
        do {
            try WstunnelBridge.stop()
            SharedLogger.log(.wstunnel, "Wstunnel stopped")
        } catch {
            SharedLogger.log(.wstunnel, "Stop error: \(error.localizedDescription)")
        }
    }
}
