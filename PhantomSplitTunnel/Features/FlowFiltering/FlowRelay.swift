import Network
import NetworkExtension
import os.log

/// Protocol the relays use to register themselves with the provider so
/// it can proactively tear them down when the selected physical
/// interface becomes UNRESOLVABLE. A change from one interface to
/// another is not that case: `handleInterfaceChange` returns on any
/// non-nil reading, so relays already running keep the interface they
/// were pinned to. Without registration we'd leave `.waiting`
/// NWConnections spinning until the app times out; strict mode
/// requires immediate close so the app sees a connection failure and
/// the user decides the next move.
protocol ActiveFlowRelayRegistry: AnyObject {
    func registerRelay(id: UUID, close: @escaping () -> Void)
    func unregisterRelay(id: UUID)
}

/// Entry point for bypass flows. Dispatches the flow to the
/// appropriate concrete relay, passing along the physical interface
/// the relay must bind its outbound `NWConnection` to. That binding
/// is what keeps bypass traffic off the tunnel's utun interface.
enum FlowRelay {

    static let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomSplitTunnel",
        category: "relay"
    )

    /// Dispatch the flow to the correct concrete relay. Returns `true`
    /// so the caller's `handleNewFlow` can return `true` (we claim it).
    /// `appName` is used by the relay when logging a flow failure so the
    /// user sees which app's connection broke and why.
    /// `registry` gets a close-callback entry so the provider can
    /// force-close the relay when the bound interface disappears.
    static func relay(
        _ flow: NEAppProxyFlow,
        appName: String,
        boundTo interface: NWInterface,
        registry: ActiveFlowRelayRegistry
    ) -> Bool {
        if let tcp = flow as? NEAppProxyTCPFlow {
            TCPFlowRelay(
                flow: tcp,
                interface: interface,
                appName: appName,
                registry: registry
            ).start()
            return true
        }
        if let udp = flow as? NEAppProxyUDPFlow {
            UDPFlowRelay(
                flow: udp,
                interface: interface,
                appName: appName,
                registry: registry
            ).start()
            return true
        }
        os_log("Unknown flow type — declining", log: log, type: .error)
        return false
    }
}
