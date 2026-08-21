#if DEBUG
import Foundation

@MainActor
final class TestVaultRawClient {

    private var connection: NSXPCConnection?

    deinit {
        connection?.invalidate()
    }

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

    func storeRaw(_ bytes: Data, id: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            let resume = SingleResume(continuation)
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
