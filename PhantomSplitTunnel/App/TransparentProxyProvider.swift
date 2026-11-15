import NetworkExtension
import Network
import os.log

final class TransparentProxyProvider: NETransparentProxyProvider, ActiveFlowRelayRegistry, ProxyConfigReceiver {

    private let log = OSLog(
        subsystem: "com.artek.Phantom-WG-MacOS.PhantomSplitTunnel",
        category: "proxy"
    )
    private let logger = RingBufferLogger.shared
    private let interfaceMonitor = InterfaceMonitor()

    private var excludedApps: [AppEntry] = []
    private let stateLock = NSLock()

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

        ProxyConfigDaemon.shared?.attach(provider: self)

        os_log("startProxy — ready", log: log, type: .default)
    }

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
        return settings
    }

    override func stopProxy(with reason: NEProviderStopReason) async {
        os_log("stopProxy — reason=%{public}d", log: log, type: .default, reason.rawValue)
        ProxyConfigDaemon.shared?.detach()
        interfaceMonitor.stop()
    }

    // MARK: - Flow Dispatch

    override func handleNewUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteEndpoint remoteEndpoint: NSObject
    ) -> Bool {
        if let endpoint = remoteEndpoint as? NWHostEndpoint, endpoint.port == Self.dnsPort {
            return leaveDNSToSystem(flow, target: "UDP  \(endpoint.hostname):\(endpoint.port)")
        }
        return handleNewFlow(flow)
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let tcp = flow as? NEAppProxyTCPFlow,
           let endpoint = tcp.remoteEndpoint as? NWHostEndpoint,
           endpoint.port == Self.dnsPort {
            return leaveDNSToSystem(flow, target: "TCP  \(endpoint.hostname):\(endpoint.port)")
        }

        let signingID: String = flow.metaData.sourceAppSigningIdentifier

        if FlowDecisionEngine.isOwnProcess(signingIdentifier: signingID) {
            return false
        }

        guard let matched = matchedExcludeApp(signingID) else {
            return false
        }

        guard let targetInterface = interfaceMonitor.current else {
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

    fileprivate static let dnsPort = "53"

    fileprivate func leaveDNSToSystem(_ flow: NEAppProxyFlow, target: String) -> Bool {
        if let matched = matchedExcludeApp(flow.metaData.sourceAppSigningIdentifier) {
            logger.log("\(matched.displayName) — DNS left to the system  \(target)")
        }
        return false
    }

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

    // MARK: - Relay Registry & Flow Helpers

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

    private func forceCloseActiveRelays() {
        relaysLock.lock()
        let closures = Array(activeRelays.values)
        relaysLock.unlock()
        for close in closures {
            close()
        }
    }

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

    func applyConfiguration(_ configuration: SplitTunnelingConfiguration) {
        stateLock.lock()
        let previous = excludedApps
        excludedApps = configuration.apps
        stateLock.unlock()
        interfaceMonitor.setSelection(configuration.interfaceSelection)
        logger.logAppDiff(previous: previous, current: configuration.apps)
    }

    private func loadConfigurationFromProviderProtocol() -> SplitTunnelingConfiguration? {
        guard let proto = self.protocolConfiguration as? NETunnelProviderProtocol,
              let data = proto.providerConfiguration?["split_config"] as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(SplitTunnelingConfiguration.self, from: data)
    }

    // MARK: - Interface Changes

    private func handleInterfaceChange(_ interface: NWInterface?) {
        if let interface {
            logger.log("interface resolved: \(interface.name) (\(interface.type))")
            return
        }
        logger.log("interface unavailable — closing active bypass flows (strict)")
        forceCloseActiveRelays()
    }
}

@available(macOS 15.0, *)
extension TransparentProxyProvider: NEAppProxyUDPFlowHandling {

    func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint) -> Bool {
        if case .hostPort(let host, let port) = remoteEndpoint, "\(port.rawValue)" == Self.dnsPort {
            return leaveDNSToSystem(flow, target: "UDP  \(host):\(port.rawValue)")
        }
        return handleNewFlow(flow)
    }
}
