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

    /// One rebuild at a time. A second request does not start a second
    /// stop/start over the first — it joins the one already running and
    /// is answered with the same outcome, so two taps can never report
    /// two different fates for one layer.
    private let resetSlotLock = NSLock()
    private var inFlightReset: Task<TunnelResetReply, Never>?

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
            // the physical interface during the reset window. The
            // second byte is the outcome: the app cannot see the layer,
            // so a reset that ended with it down has to say so.
            Task { [weak self] in
                guard let self else {
                    completionHandler(Data([3, TunnelResetReply.skipped.rawValue]))
                    return
                }
                let outcome = await self.serializedReset()
                completionHandler(Data([3, outcome.rawValue]))
            }
        default:
            completionHandler(nil)
        }
    }

    // MARK: - Layer Reset

    /// The entry point opcode 3 goes through. A rebuild already running
    /// is joined rather than raced: the second caller waits on the first
    /// one's task and is answered with its outcome, so one layer can
    /// never be torn down twice or reported two ways at once.
    private func serializedReset() async -> TunnelResetReply {
        let (reset, isOwner): (Task<TunnelResetReply, Never>, Bool) = resetSlotLock.withLock {
            if let existing = inFlightReset { return (existing, false) }
            let mine = Task { await self.resetConnection() }
            inFlightReset = mine
            return (mine, true)
        }
        guard isOwner else {
            TunnelLogger.log(.tunnel, "Reset — one is already rebuilding this layer, waiting for it")
            return await reset.value
        }
        let outcome = await reset.value
        resetSlotLock.withLock {
            if inFlightReset == reset { inFlightReset = nil }
        }
        return outcome
    }

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
    /// fallback to the physical route. That ending is returned rather
    /// than absorbed — the app has no way to see the layer, so a reset
    /// that ends with it down is indistinguishable from one that
    /// worked unless this says otherwise. The provider surface keeps
    /// traffic contained either way; the user decides the next move
    /// once they have been told which ending they got.
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
        let stopFailure: Error? = await withCheckedContinuation { continuation in
            adapter.stop { continuation.resume(returning: $0) }
        }
        if let stopFailure {
            // Not fatal on its own — the restart below is what decides
            // whether the layer comes back — but it is the first thing
            // to look at when it does not.
            TunnelLogger.log(.wireGuard, "Reset — adapter was not stopped cleanly: \(stopFailure.localizedDescription)")
        } else {
            TunnelLogger.log(.wireGuard, "Reset — adapter stopped")
        }

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
                TunnelLogger.log(.tunnel, "Reset ended with the layer down — wstunnel did not come back")
                reasserting = false
                return .wstunnelFailed
            }
        }

        let startFailure: Error? = await withCheckedContinuation { continuation in
            adapter.start(tunnelConfiguration: wireguardConfig) { continuation.resume(returning: $0) }
        }

        reasserting = false

        if let startFailure {
            TunnelLogger.log(.wireGuard, "Reset — adapter restart FAILED: \(startFailure.localizedDescription)")
            TunnelLogger.log(.tunnel, "Reset ended with the layer down — the adapter did not restart")
            return .adapterFailed
        }

        TunnelLogger.log(.wireGuard, "Reset — adapter restarted")
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
