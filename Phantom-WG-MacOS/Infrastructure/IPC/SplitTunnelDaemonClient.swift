import Foundation

@Observable
@MainActor
final class SplitTunnelDaemonClient: ProxyConfigDaemonClient {
    init() { super.init(machServiceName: ProxyConfigService.splitTunnel) }
}
