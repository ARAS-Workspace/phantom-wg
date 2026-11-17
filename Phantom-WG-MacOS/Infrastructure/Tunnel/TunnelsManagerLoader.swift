import Foundation

// MARK: - Tunnels Manager Loader

@Observable
@MainActor
class TunnelsManagerLoader {
    var manager: TunnelsManager?
    var loadError: String?

    @ObservationIgnored private var isShutDown = false

    func load(vault: TunnelVaultClient) async {
        do {
            let manager = try await TunnelsManager.create(vault: vault)
            guard !isShutDown else { return manager.shutDown() }
            await manager.reconcileFromVault()
            guard !isShutDown else { return manager.shutDown() }
            self.manager = manager
        } catch {
            loadError = error.localizedDescription
        }
    }

    func shutDown() {
        isShutDown = true
        manager?.shutDown()
    }
}
