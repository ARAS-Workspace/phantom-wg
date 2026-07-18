import Foundation

/// App-side XPC client for the PhantomDNSProxy daemon. Thin subclass of
/// `ProxyConfigDaemonClient` that pins the DNSProxy Mach service; a
/// distinct type so the SwiftUI environment can carry it alongside the
/// SplitTunnel client.
@Observable
@MainActor
final class DNSProxyDaemonClient: ProxyConfigDaemonClient {
    init() { super.init(machServiceName: ProxyConfigService.dnsProxy) }
}
