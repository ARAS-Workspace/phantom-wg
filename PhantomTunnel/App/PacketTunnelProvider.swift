import NetworkExtension
import WireGuardKit

class PacketTunnelProvider: NEPacketTunnelProvider {

    private lazy var adapter: WireGuardAdapter = {
        WireGuardAdapter(with: self) { _, message in
            wg_log(message: message)
        }
    }()

    private var wstunnelServerIPv4: [String] = []
    private var wstunnelServerIPv6: [String] = []
    private var isGhostMode = false

    /// Captured at `startTunnel` so `resetConnection` can replay the
    /// exact same layer setup without re-reading the protocol config.
    /// The tunnel is treated as one layer — ghost mode is wstunnel +
    /// WireGuard; standalone is WireGuard alone. Reset tears each
    /// component down in reverse packet-flow order and rebuilds them
    /// in forward order, never touching the provider's utun/routing
    /// surface so packets never escape to the physical interface.
    private var currentTunnelConfig: TunnelConfig?
    private var currentWireGuardConfig: TunnelConfiguration?

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        // Flush any residue from a previous session — iOS may reuse
        // the extension process across start/stop cycles, so static
        // state like the ring buffer must be reset explicitly.
        TunnelLogger.clear()
        TunnelLogger.log(.tunnel, "PacketTunnelProvider starting...")

        // 1. Decode config
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.tunnelConfig else {
            TunnelLogger.log(.tunnel, "ERROR: Invalid tunnel configuration")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }
        TunnelLogger.log(.tunnel, "Config loaded: \(config.name) (\(config.isGhostMode ? "Ghost" : "WireGuard"))")

        isGhostMode = config.isGhostMode

        // 2. Start wstunnel if Ghost mode
        if isGhostMode {
            if let host = config.wstunnel!.url.url.host {
                wstunnelServerIPv4 = DNSResolver.resolveIPv4(host)
                wstunnelServerIPv6 = DNSResolver.resolveIPv6(host)
                TunnelLogger.log(.tunnel, "Wstunnel server resolved: \(host) \u{2192} v4:\(wstunnelServerIPv4) v6:\(wstunnelServerIPv6)")
            }
            try WstunnelLifecycle.start(config: config.wstunnel!)
        }

        // 3. Build WireGuard config
        TunnelLogger.log(.wireGuard, "Building WireGuard config...")
        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try WireGuardConfigBuilder.build(
                wireguard: config.wireguard,
                wstunnel: config.wstunnel
            )
        } catch {
            WstunnelLifecycle.stop()
            throw error
        }

        // 4. Start WireGuard adapter
        TunnelLogger.log(.wireGuard, "Starting WireGuard adapter...")
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                adapter.start(tunnelConfiguration: tunnelConfiguration) { error in
                    if let error {
                        TunnelLogger.log(.wireGuard, "ERROR: \(error.localizedDescription)")
                        continuation.resume(throwing: PacketTunnelProviderError.couldNotStartWireGuard)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            WstunnelLifecycle.stop()
            throw error
        }

        // Capture the resolved layer setup so a later
        // `resetConnection()` can replay it without hitting
        // `startTunnel` (which would tear down utun and create
        // a leak window).
        currentTunnelConfig = config
        currentWireGuardConfig = tunnelConfiguration

        TunnelLogger.log(.tunnel, "Tunnel active")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        TunnelLogger.log(.tunnel, "Stopping tunnel (reason: \(reason.rawValue))")

        // Stop WireGuard first
        TunnelLogger.log(.wireGuard, "Stopping WireGuard adapter...")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            adapter.stop { _ in continuation.resume() }
        }
        TunnelLogger.log(.wireGuard, "WireGuard stopped")

        // Then stop wstunnel (idempotent — safe even if standalone)
        WstunnelLifecycle.stop()

        TunnelLogger.log(.tunnel, "Tunnel disconnected")
    }

    // MARK: - App Message

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler else { return }

        guard !messageData.isEmpty else {
            completionHandler(nil)
            return
        }

        switch messageData[0] {
        case 0:
            // WireGuard runtime stats
            adapter.getRuntimeConfiguration { config in
                completionHandler(config?.data(using: .utf8))
            }
        case 1:
            // Log entries (in-memory ring buffer snapshot)
            completionHandler(TunnelLogger.allEntriesAsData())
        case 2:
            // Flush the in-extension log buffer. Auto-purge at
            // maxEntries still applies; this is a manual flush.
            TunnelLogger.clear()
            completionHandler(Data([2]))
        case 3:
            // Reset the tunnel layer without touching utun / routing.
            // Preserves the provider surface so no packet escapes to
            // the physical interface during the reset window.
            Task { [weak self] in
                await self?.resetConnection()
                completionHandler(Data([3]))
            }
        default:
            completionHandler(nil)
        }
    }

    // MARK: - Layer Reset

    /// Restart the tunnel layer (wstunnel + WireGuard in ghost mode,
    /// WireGuard alone in standalone mode) without tearing the
    /// `utun` interface or its routes down. Packets that arrive on
    /// `utun` during the reset window are dropped inside the layer —
    /// they never reach the physical interface — so there is no leak.
    ///
    /// Sequence matches the established start/stop ordering:
    ///   STOP  (top-down):  WireGuard → wstunnel
    ///   START (bottom-up): wstunnel → WireGuard
    ///
    /// Failure semantics: if any restart step fails, the layer is
    /// left in a "no traffic flowing" state with `utun` still up. No
    /// fallback to the physical route. The user retries via the UI
    /// or disables the tunnel — the provider surface keeps traffic
    /// contained until the user decides the next move.
    private func resetConnection() async {
        guard let config = currentTunnelConfig,
              let wireguardConfig = currentWireGuardConfig else {
            TunnelLogger.log(.tunnel, "Reset skipped — no active layer config")
            return
        }

        let modeLabel = isGhostMode ? "Ghost (wstunnel + WireGuard)" : "Standalone (WireGuard)"
        TunnelLogger.log(.tunnel, "Reset — restarting layer (\(modeLabel))")

        // Signal the OS that the tunnel is transitioning but still
        // intended to be up. Keeps `utun` anchored and keeps the
        // session status in `.reasserting` throughout the cycle.
        reasserting = true

        // STOP PHASE — top-down
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            adapter.stop { _ in continuation.resume() }
        }
        TunnelLogger.log(.wireGuard, "Reset — adapter stopped")

        if isGhostMode {
            WstunnelLifecycle.stop()
            TunnelLogger.log(.wstunnel, "Reset — wstunnel stopped")
        }

        // START PHASE — bottom-up
        if isGhostMode, let wstunnelConfig = config.wstunnel {
            do {
                try WstunnelLifecycle.start(config: wstunnelConfig)
                TunnelLogger.log(.wstunnel, "Reset — wstunnel restarted")
            } catch {
                TunnelLogger.log(.wstunnel, "Reset — wstunnel restart FAILED: \(error.localizedDescription)")
                reasserting = false
                return
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            adapter.start(tunnelConfiguration: wireguardConfig) { error in
                if let error {
                    TunnelLogger.log(.wireGuard, "Reset — adapter restart FAILED: \(error.localizedDescription)")
                } else {
                    TunnelLogger.log(.wireGuard, "Reset — adapter restarted")
                }
                continuation.resume()
            }
        }

        reasserting = false
        TunnelLogger.log(.tunnel, "Reset complete")
    }

    // MARK: - Network Settings Override

    override func setTunnelNetworkSettings(_ tunnelNetworkSettings: NETunnelNetworkSettings?,
                                           completionHandler: ((Error?) -> Void)? = nil) {
        if let settings = tunnelNetworkSettings as? NEPacketTunnelNetworkSettings {
            NetworkSettingsManager.apply(
                to: settings,
                excludedIPv4: wstunnelServerIPv4,
                excludedIPv6: wstunnelServerIPv6,
                isGhostMode: isGhostMode
            )
        }

        super.setTunnelNetworkSettings(tunnelNetworkSettings, completionHandler: completionHandler)
    }
}
