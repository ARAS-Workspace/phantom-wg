import Foundation

// MARK: - Reset (Layer-Level)

extension TunnelsManager {

    /// Ask the extension to restart its tunnel layer (wstunnel +
    /// WireGuard in ghost mode, WireGuard alone in standalone) in
    /// place — the `utun` interface and its routes stay up, so
    /// nothing leaks out onto the physical NIC while the layer is
    /// rebuilt. Triggered by the user's "Reset Connection" button
    /// when the tunnel appears stuck.
    ///
    /// Extension uses opcode `3`; the handler replies only after the
    /// full stop/start sequence completes, so this wrapper returning
    /// means the layer has been rebuilt (the WireGuard handshake
    /// itself may still be settling).
    func resetConnection(of tunnel: TunnelContainer) async throws {
        guard tunnel.status == .active || tunnel.status == .reasserting else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try tunnel.tunnelProvider.sendProviderMessage(Data([3])) { _ in
                    continuation.resume()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
