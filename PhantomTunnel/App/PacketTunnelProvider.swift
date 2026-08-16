import NetworkExtension
import WireGuardKit
import os.log

private let extLog = OSLog(subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomTunnel", category: "tunnel")

class PacketTunnelProvider: NEPacketTunnelProvider {

    private lazy var adapter: WireGuardAdapter = {
        WireGuardAdapter(with: self) { _, message in
            wg_log(message: message)
        }
    }()

    /// Resolved wstunnel server addresses (for excluded routes)
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

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        os_log("startTunnel called", log: extLog, type: .default)
        TunnelLogger.log(.tunnel, "PacketTunnelProvider starting...")

        // 1. Identity from providerConfiguration, secrets from the vault.
        guard let config = loadConfig() else {
            completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            return
        }

        os_log("Config loaded: %{public}@", log: extLog, type: .default, config.name)
        TunnelLogger.log(.tunnel, "Config loaded: \(config.name)")

        // 2-3. Wstunnel (Ghost mode only)
        do {
            try startWstunnelIfNeeded(config: config)
        } catch {
            completionHandler(error)
            return
        }

        // 4. Build WireGuard config (ghost: endpoint = the wstunnel
        //    listener at localHost:localPort; standalone: the peer
        //    endpoint carried verbatim)
        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try WireGuardConfigBuilder.build(
                wireguard: config.wireguard, wstunnel: config.wstunnel
            )
        } catch {
            WstunnelLifecycle.stop()
            TunnelLogger.log(.wireGuard, "ERROR: Config build failed - \(error.localizedDescription)")
            completionHandler(error)
            return
        }

        // 5. Start WireGuard adapter
        TunnelLogger.log(.wireGuard, "Starting WireGuard adapter...")
        adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] adapterError in
            if let adapterError {
                WstunnelLifecycle.stop()
                TunnelLogger.log(.wireGuard, "ERROR: \(adapterError.localizedDescription)")
                completionHandler(PacketTunnelProviderError.couldNotStartWireGuard)
            } else {
                // Capture the resolved layer setup so a later
                // `resetConnection()` can replay it without hitting
                // `startTunnel` (which would tear down utun and
                // create a leak window).
                self?.currentTunnelConfig = config
                self?.currentWireGuardConfig = tunnelConfiguration
                TunnelLogger.log(.tunnel, "Tunnel active")
                completionHandler(nil)
            }
        }
    }

    /// The system's preferences carry identity only; the secrets come
    /// from this extension's own System keychain vault, read here
    /// in-process — no XPC hop, and nothing sensitive ever lands in a
    /// world-readable plist.
    private func loadConfig() -> TunnelConfig? {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
            os_log("ERROR: protocolConfiguration is not NETunnelProviderProtocol", log: extLog, type: .error)
            return nil
        }

        guard let identity = proto.tunnelIdentity else {
            os_log("ERROR: tunnel identity missing from providerConfiguration", log: extLog, type: .error)
            TunnelLogger.log(.tunnel, "ERROR: Tunnel identity missing")
            return nil
        }

        let configId = identity.id.uuidString
        guard let payload = SystemKeychainVault.fetchForProvider(id: configId),
              let config = try? JSONDecoder().decode(TunnelConfig.self, from: payload) else {
            os_log("ERROR: vault holds no usable payload (configId: %{public}@)",
                   log: extLog, type: .error, configId)
            TunnelLogger.log(.tunnel, "ERROR: Vault fetch failed (configId: \(configId))")
            return nil
        }

        return config
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        os_log("stopTunnel called (reason: %d)", log: extLog, type: .default, reason.rawValue)
        TunnelLogger.log(.tunnel, "Stopping tunnel (reason: \(reason.rawValue))")

        adapter.stop { _ in
            WstunnelLifecycle.stop()
            TunnelLogger.log(.tunnel, "Tunnel disconnected")
            completionHandler()

            // Exiting does not stand recovery down — the on-demand
            // rule lives in the system's preferences, not in this
            // process. The app's stop path disarms before it stops;
            // a stop from outside the app (System Settings) leaves
            // the rule armed, so the system may start this tunnel
            // again.
            #if os(macOS)
            exit(0)
            #endif
        }
    }

    // MARK: - Wstunnel

    private func startWstunnelIfNeeded(config: TunnelConfig) throws {
        guard let wstunnel = config.wstunnel else {
            TunnelLogger.log(.tunnel, "Standalone WireGuard mode (no wstunnel)")
            isGhostMode = false
            return
        }

        isGhostMode = true

        if let host = wstunnel.url.url.host {
            wstunnelServerIPv4 = DNSResolver.resolveIPv4(host)
            wstunnelServerIPv6 = DNSResolver.resolveIPv6(host)
            TunnelLogger.log(.tunnel, "DNS: \(host) -> v4:\(wstunnelServerIPv4) v6:\(wstunnelServerIPv6)")
        }

        do {
            try WstunnelLifecycle.start(config: wstunnel)
        } catch {
            TunnelLogger.log(.wstunnel, "ERROR: \(error.localizedDescription)")
            throw error
        }
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
            // Log entries (in-memory buffer)
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
            //
            // The reply carries the outcome as its second byte. A
            // `self` that has gone away cannot have rebuilt anything,
            // so it answers `skipped` rather than the success value a
            // `??` on the optional would have handed back.
            Task { [weak self] in
                let outcome = await self?.resetConnection() ?? .skipped
                completionHandler(Data([3, outcome.rawValue]))
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
    ///
    /// Which of those four endings happened is the RETURN VALUE, and
    /// it becomes the second byte of opcode 3's reply. Before it
    /// existed, all four left the caller the same single byte, and
    /// three of them were failures — including one that logged
    /// "Reset complete" on its way out (see the adapter branch).
    private func resetConnection() async -> TunnelResetReply {
        guard let config = currentTunnelConfig,
              let wireguardConfig = currentWireGuardConfig else {
            TunnelLogger.log(.tunnel, "Reset skipped — no active layer config")
            return .skipped
        }

        let modeLabel = isGhostMode ? "Ghost (wstunnel + WireGuard)" : "Standalone (WireGuard)"
        TunnelLogger.log(.tunnel, "Reset — restarting layer (\(modeLabel))")

        // Signal the OS that the tunnel is transitioning but still
        // intended to be up. Keeps `utun` anchored and keeps the
        // session status in `.reasserting` throughout the cycle.
        reasserting = true

        // STOP PHASE — top-down
        await withCheckedContinuation { continuation in
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
                return .wstunnelFailed
            }
        }

        // The adapter's own failure is carried out of the closure
        // rather than only logged inside it. It used to be logged and
        // dropped, and control fell straight through to the line
        // below — so a reset whose adapter never came back announced
        // "Reset complete" to the log and answered the app with the
        // same byte a working reset did. A description rather than
        // the error itself, because only the text crosses back.
        let adapterFailure: String? = await withCheckedContinuation { continuation in
            adapter.start(tunnelConfiguration: wireguardConfig) { error in
                if let error {
                    TunnelLogger.log(.wireGuard, "Reset — adapter restart FAILED: \(error.localizedDescription)")
                    continuation.resume(returning: error.localizedDescription)
                } else {
                    TunnelLogger.log(.wireGuard, "Reset — adapter restarted")
                    continuation.resume(returning: nil)
                }
            }
        }

        reasserting = false
        if adapterFailure != nil {
            // Deliberately not "Reset complete". The layer is down
            // under a utun that is still up: contained, not working.
            TunnelLogger.log(.tunnel, "Reset ended with the layer down — the adapter did not restart")
            return .adapterFailed
        }
        TunnelLogger.log(.tunnel, "Reset complete")
        return .rebuilt
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
