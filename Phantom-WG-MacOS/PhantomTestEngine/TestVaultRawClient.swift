// ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
// ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
// ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
// ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
// ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
// ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
//
// Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
// Licensed under AGPL-3.0 - see LICENSE file for details
// WireGuard® is a registered trademark of Jason A. Donenfeld.
//
// Test Engine: Raw Vault Writer
//
// Writes arbitrary BYTES into the tunnel vault over XPC, bypassing the
// typed client entirely. Its reason to exist is planting payloads the
// typed path could never produce — an undecodable one, so a workflow can
// measure what custody does with a payload it cannot read.
//
// It reaches the daemon only because the test engine runs inside the host
// app: `TunnelVaultDaemon` pins its peer to this bundle identifier, and a
// Debug build carries the same identifier as Release.
//
// Answers `false` on any failure and on a five-second silence.

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
