import NetworkExtension
import Network
import os.log

/// Independent split-tunnelling provider. Bypass flows for listed
/// apps are pinned to a specific physical interface via
/// `NWConnection.requiredInterface`. Strict mode: no interface →
/// reject the flow rather than letting it leak through the OS
/// default route.
final class TransparentProxyProvider: NETransparentProxyProvider, ActiveFlowRelayRegistry, ProxyConfigReceiver {

    private let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomSplitTunnel",
        category: "proxy"
    )
    private let logger = RingBufferLogger.shared
    private let interfaceMonitor = InterfaceMonitor()

    /// Written from the daemon's XPC config push, read from NE
    /// flow-dispatch threads — every access goes through `stateLock`,
    /// mirroring `DNSProxyProvider`.
    private var excludedApps: [AppEntry] = []
    private let stateLock = NSLock()

    /// Live relay registry. Each `TCPFlowRelay` / `UDPFlowRelay`
    /// registers a close-closure on start and unregisters on close,
    /// so we can tear down every active flow in one pass when the
    /// bound interface goes away.
    private var activeRelays: [UUID: () -> Void] = [:]
    private let relaysLock = NSLock()

    // MARK: - Lifecycle

    override func startProxy(options: [String: Any]? = nil) async throws {
        os_log("startProxy — loading configuration", log: log, type: .default)

        try await setTunnelNetworkSettings(buildNetworkSettings())

        interfaceMonitor.onChange = { [weak self] interface in
            self?.handleInterfaceChange(interface)
        }
        interfaceMonitor.start()

        let initialConfig = loadConfigurationFromProviderProtocol() ?? .default
        applyConfiguration(initialConfig)

        // Attach LAST: the daemon replays any config pushed while no
        // provider was attached, so the drained payload must land
        // after the (possibly stale) preference bootstrap above —
        // the fresher writer always wins.
        ProxyConfigDaemon.shared?.attach(provider: self)

        os_log("startProxy — ready", log: log, type: .default)
    }

    /// Includes every outbound flow via dual-stack wildcard, then
    /// carves out port 53 (UDP/TCP × IPv4/IPv6) so DNS flows reach
    /// PhantomDNSProxy instead.
    private func buildNetworkSettings() -> NETransparentProxyNetworkSettings {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(
                remoteNetwork: nil,
                remotePrefix: 0,
                localNetwork: nil,
                localPrefix: 0,
                protocol: .any,
                direction: .outbound
            )
        ]
        settings.excludedNetworkRules = Self.dnsCarveOutRules()
        return settings
    }

    private static func dnsCarveOutRules() -> [NENetworkRule] {
        let hosts = ["0.0.0.0", "::"]
        let protos: [NENetworkRule.`Protocol`] = [.UDP, .TCP]
        return hosts.flatMap { host in
            protos.map { proto in
                NENetworkRule(
                    remoteNetwork: NWHostEndpoint(hostname: host, port: "53"),
                    remotePrefix: 0,
                    localNetwork: nil,
                    localPrefix: 0,
                    protocol: proto,
                    direction: .outbound
                )
            }
        }
    }

    override func stopProxy(with reason: NEProviderStopReason) async {
        os_log("stopProxy — reason=%{public}d", log: log, type: .default, reason.rawValue)
        ProxyConfigDaemon.shared?.detach()
        interfaceMonitor.stop()
    }

    // MARK: - Flow Dispatch

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let signingID: String = flow.metaData.sourceAppSigningIdentifier

        if FlowDecisionEngine.isOwnProcess(signingIdentifier: signingID) {
            return false
        }

        guard let matched = matchedExcludeApp(signingID) else {
            return false
        }

        guard let targetInterface = interfaceMonitor.current else {
            // Strict: claim the flow and reject so it never falls
            // through to the tunnel via the OS default route.
            logger.log(
                "\(matched.displayName) — bypass unavailable, flow rejected (strict)  \(describeFlow(flow))"
            )
            rejectFlow(flow, error: POSIXError(.EHOSTUNREACH))
            return true
        }

        logger.log("\(matched.displayName) → \(targetInterface.name)  \(describeFlow(flow))")
        return FlowRelay.relay(
            flow,
            appName: matched.displayName,
            boundTo: targetInterface,
            registry: self
        )
    }

    /// Open the flow then immediately close both halves with the
    /// error. `closeReadWithError` / `closeWriteWithError` deliver
    /// the error to the app's socket only after the flow leaves
    /// pending-open state.
    private func rejectFlow(_ flow: NEAppProxyFlow, error: Error) {
        if let tcp = flow as? NEAppProxyTCPFlow {
            tcp.open(withLocalEndpoint: nil) { _ in
                tcp.closeReadWithError(error)
                tcp.closeWriteWithError(error)
            }
        } else if let udp = flow as? NEAppProxyUDPFlow {
            udp.open(withLocalEndpoint: nil) { _ in
                udp.closeReadWithError(error)
                udp.closeWriteWithError(error)
            }
        }
    }

    // MARK: - ActiveFlowRelayRegistry

    func registerRelay(id: UUID, close: @escaping () -> Void) {
        relaysLock.lock()
        activeRelays[id] = close
        relaysLock.unlock()
    }

    func unregisterRelay(id: UUID) {
        relaysLock.lock()
        activeRelays.removeValue(forKey: id)
        relaysLock.unlock()
    }

    /// Drain the registry and fire every close-closure. Snapshot is
    /// taken under the lock so concurrent unregister inside each
    /// close flow is safe.
    private func forceCloseActiveRelays() {
        relaysLock.lock()
        let closures = Array(activeRelays.values)
        relaysLock.unlock()
        for close in closures {
            close()
        }
    }

    /// Per-flow LogView summary. TCP carries a single endpoint; UDP
    /// dispatches to many destinations over the session, so at flow
    /// open we can only report the protocol tag.
    private func describeFlow(_ flow: NEAppProxyFlow) -> String {
        if let tcp = flow as? NEAppProxyTCPFlow,
           let endpoint = tcp.remoteEndpoint as? NWHostEndpoint {
            return "TCP  \(endpoint.hostname):\(endpoint.port)"
        }
        if flow is NEAppProxyUDPFlow {
            return "UDP"
        }
        return "?"
    }

    private func matchedExcludeApp(_ signingID: String) -> AppEntry? {
        stateLock.lock()
        let apps = excludedApps
        stateLock.unlock()
        return apps.first { FlowDecisionEngine.matches(signingID: signingID, against: $0) }
    }

    // MARK: - Configuration

    /// Apply the decoded configuration to in-memory state. Called from
    /// `startProxy` (bootstrap from providerConfiguration) and from
    /// `ProxyConfigDaemon.applyConfig` (live XPC push from the host app).
    /// Logs the app-list diff against the previous state so the user can
    /// see additions/removals.
    func applyConfiguration(_ configuration: SplitTunnelingConfiguration) {
        stateLock.lock()
        let previous = excludedApps
        excludedApps = configuration.apps
        stateLock.unlock()
        interfaceMonitor.setSelection(configuration.interfaceSelection)
        logger.logAppDiff(previous: previous, current: configuration.apps)
    }

    /// Initial config from
    /// `NETunnelProviderProtocol.providerConfiguration` (packed by
    /// the main app at `saveToPreferences`).
    private func loadConfigurationFromProviderProtocol() -> SplitTunnelingConfiguration? {
        guard let proto = self.protocolConfiguration as? NETunnelProviderProtocol,
              let data = proto.providerConfiguration?["split_config"] as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(SplitTunnelingConfiguration.self, from: data)
    }

    // MARK: - Interface Loss

    /// Strict mode: when the resolved interface becomes NIL we tear
    /// down every active relay rather than letting them stall in
    /// `NWConnection`'s `.waiting`. New flows get rejected by
    /// `handleNewFlow`.
    private func handleInterfaceChange(_ interface: NWInterface?) {
        if let interface {
            logger.log("interface resolved: \(interface.name) (\(interface.type))")
            return
        }
        logger.log("interface unavailable — closing active bypass flows (strict)")
        forceCloseActiveRelays()
    }
}
