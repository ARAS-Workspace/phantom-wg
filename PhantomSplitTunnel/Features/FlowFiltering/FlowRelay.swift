import Network
import NetworkExtension
import os.log

protocol ActiveFlowRelayRegistry: AnyObject {
    func registerRelay(id: UUID, close: @escaping () -> Void)
    func unregisterRelay(id: UUID)
}

enum FlowRelay {

    static let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomSplitTunnel",
        category: "relay"
    )

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
