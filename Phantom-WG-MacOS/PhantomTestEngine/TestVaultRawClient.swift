#if DEBUG
import Foundation

/// Raw XPC path to the vault daemon, below the app's `TunnelVaultClient`.
/// The production client only ever encodes a valid `TunnelConfig`, so
/// the undecodable-payload paths (read reporting, reconcile survival)
/// can be reached no other way. This writes ARBITRARY bytes under an id.
///
/// It reuses the exact contract the app uses — `TunnelVaultDaemonProtocol`
/// over `TunnelVaultService.machServiceName` — so the daemon pins it to
/// our own team/identifier just like the real client; it works only
/// because the test engine runs as the host app. Used solely by
/// injection steps; every id it writes is deleted on the way out.
@MainActor
final class TestVaultRawClient {

    private var connection: NSXPCConnection?

    private func proxy(_ onError: @escaping @Sendable (Error) -> Void) -> TunnelVaultDaemonProtocol? {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: TunnelVaultService.machServiceName, options: [])
            conn.remoteObjectInterface = NSXPCInterface(with: TunnelVaultDaemonProtocol.self)
            conn.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            conn.resume()
            connection = conn
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? TunnelVaultDaemonProtocol
    }

    /// Writes raw bytes under `id`, bypassing `TunnelConfig` encoding.
    /// Returns the daemon's ack, or false if the vault could not be reached.
    func storeRaw(_ bytes: Data, id: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            let resume = StepResume(continuation)
            guard let proxy = proxy({ _ in resume.finish(false) }) else {
                resume.finish(false)
                return
            }
            proxy.storeVault(bytes, id: id.uuidString) { ok in resume.finish(ok) }
            Task { try? await Task.sleep(for: .seconds(5)); resume.finish(false) }
        }
    }
}
#endif
