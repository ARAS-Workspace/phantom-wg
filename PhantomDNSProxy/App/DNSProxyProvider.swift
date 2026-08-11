import Foundation
import Network
import NetworkExtension
import SystemConfiguration
import os.log

/// PhantomDNSProxy provider. Per-flow decision:
/// - Own process → declined back to OS default route
/// - Listed app + physical interface present + resolver configured
///   → relay to that resolver, pinned to the interface
/// - Listed app + missing interface or resolver → reject
/// - Unmatched → relay to system default resolver (no pin)
final class DNSProxyProvider: NEDNSProxyProvider, ProxyConfigReceiver {

    private let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomDNSProxy",
        category: "provider"
    )
    private let logger = RingBufferLogger.shared
    private let interfaceMonitor = InterfaceMonitor()

    private var listedApps: [AppEntry] = []
    private let stateLock = NSLock()

    /// One log line per signing identifier on first sight; cleared
    /// on every `applyConfiguration`.
    private var seenSigningIDs: Set<String> = []

    // MARK: - Lifecycle

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        os_log("startProxy ENTER  optionsKeys=%{public}@",
               log: log, type: .default,
               options.map { "\(Array($0.keys))" } ?? "<nil>")
        logger.log("startProxy")

        interfaceMonitor.onChange = { [weak self] interface in
            if let interface {
                self?.logger.log("interface resolved: \(interface.name)")
            } else {
                self?.logger.log("interface unavailable — matched flows will be rejected")
            }
        }
        interfaceMonitor.start()

        let initial = loadConfiguration(options: options) ?? .default
        logger.log("config loaded: apps=\(initial.apps.count)")
        applyConfiguration(initial)

        // Attach LAST: the daemon replays any config pushed while no
        // provider was attached, so the drained payload must land
        // after the (possibly stale) options bootstrap above — the
        // fresher writer always wins.
        ProxyConfigDaemon.shared?.attach(provider: self)

        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.log("stopProxy reason=\(reason.rawValue)")
        ProxyConfigDaemon.shared?.detach()
        interfaceMonitor.stop()
        completionHandler()
    }

    // MARK: - Flow Dispatch

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let signingID = flow.metaData.sourceAppSigningIdentifier

        if FlowDecisionEngine.isOwnProcess(signingIdentifier: signingID) {
            return false
        }

        stateLock.lock()
        let firstTime = seenSigningIDs.insert(signingID).inserted
        let listSize = listedApps.count
        let listedSigningIDs = listedApps.map { $0.signingIdentifier }.joined(separator: ",")
        stateLock.unlock()

        let matched = matchedApp(signingID)

        if firstTime {
            let result = matched != nil ? "MATCHED→\(matched!.signingIdentifier)" : "no-match"
            let id = signingID.isEmpty ? "<empty>" : signingID
            logger.log("first flow signingID=\(id)  result=\(result)  listSize=\(listSize)  configured=[\(listedSigningIDs)]")
        }

        if let matched {
            return handleMatchedFlow(flow, matched: matched)
        }

        return handleUnmatchedFlow(flow)
    }

    /// Listed app branch. Rejects with EHOSTUNREACH when no
    /// physical interface is available or the chosen interface has
    /// no configured resolver.
    private func handleMatchedFlow(_ flow: NEAppProxyFlow, matched: AppEntry) -> Bool {
        let flowKind = (flow is NEAppProxyTCPFlow) ? "TCP" : "UDP"

        guard let targetInterface = interfaceMonitor.current else {
            logger.log("REJECT \(matched.displayName) \(flowKind): no physical interface")
            rejectFlow(flow, error: POSIXError(.EHOSTUNREACH))
            return true
        }
        guard let resolver = InterfaceDNSResolver.dnsServers(for: targetInterface.name).first else {
            logger.log("REJECT \(matched.displayName) \(flowKind): no DNS configured on \(targetInterface.name)")
            rejectFlow(flow, error: POSIXError(.EHOSTUNREACH))
            return true
        }

        logger.log("MATCHED \(matched.displayName) \(flowKind) → \(resolver):53 via \(targetInterface.name)")
        return DNSFlowRelay.relay(
            flow,
            appName: matched.displayName,
            resolver: resolver,
            boundTo: targetInterface
        )
    }

    /// Unmatched apps relay to the system default resolver without
    /// a pin. No per-flow log emitted.
    private func handleUnmatchedFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let resolver = systemDefaultResolver() else {
            rejectFlow(flow, error: POSIXError(.EHOSTUNREACH))
            return true
        }
        return DNSFlowRelay.relay(
            flow,
            appName: flow.metaData.sourceAppSigningIdentifier,
            resolver: resolver,
            boundTo: nil
        )
    }

    /// First scoped entry from `systemDNSSettings`, with
    /// `InterfaceDNSResolver.globalResolverServers()` as fallback —
    /// `systemDNSSettings` returns nil for DoH/DoT-capable resolvers.
    private func systemDefaultResolver() -> String? {
        if let settings = systemDNSSettings {
            for entry in settings where !entry.servers.isEmpty {
                return entry.servers.first
            }
        }
        return InterfaceDNSResolver.globalResolverServers().first
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

    private func matchedApp(_ signingID: String) -> AppEntry? {
        stateLock.lock()
        let apps = listedApps
        stateLock.unlock()
        return apps.first { FlowDecisionEngine.matches(signingID: signingID, against: $0) }
    }

    // MARK: - Configuration

    /// Apply a decoded configuration to in-memory state. Called
    /// from `startProxy` (initial bootstrap from
    /// `providerConfiguration`) and from `ProxyConfigDaemon.applyConfig`
    /// (live XPC push from the host app). The list is honored
    /// verbatim. Logs the app-list diff against the previous state.
    func applyConfiguration(_ configuration: SplitTunnelingConfiguration) {
        stateLock.lock()
        let previous = listedApps
        listedApps = configuration.apps
        seenSigningIDs.removeAll(keepingCapacity: true)
        stateLock.unlock()

        logger.logAppDiff(previous: previous, current: configuration.apps)

        interfaceMonitor.setSelection(configuration.interfaceSelection)
    }

    /// Decodes `SplitTunnelingConfiguration` from `startProxy` options.
    /// Lookup order:
    /// 1. `options["split_config"]` (Data) — top-level direct
    /// 2. `options["VendorData"]` as `[String: Any]` containing
    ///    `split_config` Data
    /// 3. `options["VendorData"]` as plist-encoded `Data` decoding
    ///    into the same dict
    private func loadConfiguration(options: [String: Any]?) -> SplitTunnelingConfiguration? {
        guard let options else {
            os_log("loadConfiguration: options is nil",
                   log: log, type: .error)
            return nil
        }

        if let direct = options["split_config"] as? Data {
            os_log("loadConfiguration: top-level split_config %{public}d bytes",
                   log: log, type: .default, direct.count)
            return decode(direct, source: "options.split_config")
        }

        if let vendorDict = options["VendorData"] as? [String: Any] {
            os_log("loadConfiguration: VendorData is dict (keys=%{public}@)",
                   log: log, type: .default, "\(Array(vendorDict.keys))")
            if let data = vendorDict["split_config"] as? Data {
                return decode(data, source: "VendorData.split_config(dict)")
            }
            os_log("loadConfiguration: VendorData dict has no split_config",
                   log: log, type: .error)
            return nil
        }

        if let vendorData = options["VendorData"] as? Data {
            os_log("loadConfiguration: VendorData is Data %{public}d bytes — decoding plist",
                   log: log, type: .default, vendorData.count)
            do {
                let plist = try PropertyListSerialization.propertyList(
                    from: vendorData, options: [], format: nil
                )
                if let dict = plist as? [String: Any] {
                    os_log("loadConfiguration: plist dict keys=%{public}@",
                           log: log, type: .default, "\(Array(dict.keys))")
                    if let inner = dict["split_config"] as? Data {
                        return decode(inner, source: "VendorData.split_config(plist)")
                    }
                    os_log("loadConfiguration: plist dict has no split_config",
                           log: log, type: .error)
                    return nil
                }
                os_log("loadConfiguration: VendorData plist is not [String: Any] (got %{public}@)",
                       log: log, type: .error, "\(type(of: plist))")
            } catch {
                os_log("loadConfiguration: VendorData plist decode FAILED — %{public}@",
                       log: log, type: .error, "\(error)")
            }
            return nil
        }

        os_log("loadConfiguration: no VendorData on any shape (keys=%{public}@)",
               log: log, type: .error, "\(Array(options.keys))")
        return nil
    }

    private func decode(_ data: Data, source: String) -> SplitTunnelingConfiguration? {
        do {
            let config = try JSONDecoder().decode(SplitTunnelingConfiguration.self, from: data)
            os_log("loadConfiguration: decoded from %{public}@ — apps=%{public}d",
                   log: log, type: .default, source, config.apps.count)
            return config
        } catch {
            os_log("loadConfiguration: decode FAILED from %{public}@ — %{public}@",
                   log: log, type: .error, source, "\(error)")
            return nil
        }
    }
}
