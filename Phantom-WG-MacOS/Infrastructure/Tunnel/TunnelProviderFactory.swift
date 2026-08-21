import NetworkExtension

protocol TunnelProviderFactory {
    func makeProvider() -> TunnelProviding
    func loadAllFromPreferences() async throws -> [TunnelProviding]
}

struct RealTunnelProviderFactory: TunnelProviderFactory {

    func makeProvider() -> TunnelProviding {
        NETunnelProviderManager()
    }

    func loadAllFromPreferences() async throws -> [TunnelProviding] {
        try await NETunnelProviderManager.loadAllFromPreferences()
    }
}
