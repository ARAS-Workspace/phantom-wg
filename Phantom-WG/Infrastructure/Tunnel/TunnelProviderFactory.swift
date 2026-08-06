import NetworkExtension

/// Factory for creating and loading tunnel providers — the seam that
/// lets `TunnelsManager` run against something other than the live
/// NE preferences store. Production uses RealTunnelProviderFactory;
/// previews inject PreviewTunnelProviderFactory.
protocol TunnelProviderFactory {
    func makeProvider() -> TunnelProviding
    func loadAllFromPreferences() async throws -> [TunnelProviding]
}

/// Production factory that creates real NETunnelProviderManager instances.
struct RealTunnelProviderFactory: TunnelProviderFactory {

    func makeProvider() -> TunnelProviding {
        NETunnelProviderManager()
    }

    func loadAllFromPreferences() async throws -> [TunnelProviding] {
        try await NETunnelProviderManager.loadAllFromPreferences()
    }
}
