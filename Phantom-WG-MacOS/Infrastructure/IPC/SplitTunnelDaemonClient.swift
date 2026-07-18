import Foundation

/// App-side XPC client for the PhantomSplitTunnel daemon. Thin subclass
/// of `ProxyConfigDaemonClient` that pins the SplitTunnel Mach service;
/// a distinct type so the SwiftUI environment can carry it alongside the
/// DNSProxy client.
@Observable
@MainActor
final class SplitTunnelDaemonClient: ProxyConfigDaemonClient {
    init() { super.init(machServiceName: ProxyConfigService.splitTunnel) }
}
