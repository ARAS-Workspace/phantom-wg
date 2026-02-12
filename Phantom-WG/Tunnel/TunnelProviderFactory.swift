import NetworkExtension

/// Factory for creating and loading tunnel providers.
/// Production uses RealTunnelProviderFactory; tests inject MockTunnelProviderFactory.
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
