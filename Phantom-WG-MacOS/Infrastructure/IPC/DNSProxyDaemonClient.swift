import Foundation

@Observable
@MainActor
final class DNSProxyDaemonClient: ProxyConfigDaemonClient {
    init() { super.init(machServiceName: ProxyConfigService.dnsProxy) }
}
