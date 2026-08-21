import Foundation

// MARK: - Tunnels Manager Loader

@Observable
@MainActor
class TunnelsManagerLoader {
    var manager: TunnelsManager?
    var loadError: String?

    func load(vault: TunnelVaultClient) async {
        do {
            let manager = try await TunnelsManager.create(vault: vault)
            await manager.reconcileFromVault()
            self.manager = manager
        } catch {
            loadError = error.localizedDescription
        }
    }
}
