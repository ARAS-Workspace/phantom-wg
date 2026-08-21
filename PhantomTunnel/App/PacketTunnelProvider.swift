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

    private var wstunnelServerIPv4: [String] = []
    private var wstunnelServerIPv6: [String] = []
    private var isGhostMode = false

    private var currentTunnelConfig: TunnelConfig?
    private var currentWireGuardConfig: TunnelConfiguration?

    private let resetSlotLock = NSLock()
    private var inFlightReset: Task<TunnelResetReply, Never>?

    // MARK: - Tunnel Lifecycle

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        os_log("startTunnel called", log: extLog, type: .default)
        TunnelLogger.log(.tunnel, "PacketTunnelProvider starting...")

        guard let config = loadConfig() else {
            completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            return
        }

        os_log("Config loaded: %{public}@", log: extLog, type: .default, config.name)
        TunnelLogger.log(.tunnel, "Config loaded: \(config.name)")

        do {
            try startWstunnelIfNeeded(config: config)
        } catch {
            completionHandler(error)
            return
        }

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

        TunnelLogger.log(.wireGuard, "Starting WireGuard adapter...")
        adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] adapterError in
            if let adapterError {
                WstunnelLifecycle.stop()
                TunnelLogger.log(.wireGuard, "ERROR: \(adapterError.localizedDescription)")
                completionHandler(PacketTunnelProviderError.couldNotStartWireGuard)
            } else {
                self?.currentTunnelConfig = config
                self?.currentWireGuardConfig = tunnelConfiguration
                TunnelLogger.log(.tunnel, "Tunnel active")
                completionHandler(nil)
            }
        }
    }

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
            adapter.getRuntimeConfiguration { config in
                completionHandler(config?.data(using: .utf8))
            }
        case 1:
            completionHandler(TunnelLogger.allEntriesAsData())
        case 2:
            TunnelLogger.clear()
            completionHandler(Data([2]))
        case 3:
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

    private func resetConnection() async -> TunnelResetReply {
        guard let config = currentTunnelConfig,
              let wireguardConfig = currentWireGuardConfig else {
            TunnelLogger.log(.tunnel, "Reset skipped — no active layer config")
            return .skipped
        }

        let modeLabel = isGhostMode ? "Ghost (wstunnel + WireGuard)" : "Standalone (WireGuard)"
        TunnelLogger.log(.tunnel, "Reset — restarting layer (\(modeLabel))")

        reasserting = true

        let stopFailure: String? = await withCheckedContinuation { continuation in
            adapter.stop { error in continuation.resume(returning: error?.localizedDescription) }
        }
        if let stopFailure {
            TunnelLogger.log(.wireGuard, "Reset — adapter was not stopped: \(stopFailure)")
        } else {
            TunnelLogger.log(.wireGuard, "Reset — adapter stopped")
        }

        if isGhostMode {
            WstunnelLifecycle.stop()
            TunnelLogger.log(.wstunnel, "Reset — wstunnel stopped")
        }

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
