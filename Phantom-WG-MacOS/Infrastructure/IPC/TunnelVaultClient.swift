import Foundation
import Observation
import os.log

/// App-side XPC client for the tunnel extension's secret custody.
///
/// The System keychain is root-owned and this app is a sandboxed user
/// process, so it never touches the vault directly — it asks the
/// extension, which launchd spawns on demand for the Mach service.
/// Every tunnel mutation (import, edit, delete) goes through here, and
/// the read path is what the detail and edit screens use to show a
/// configuration.
///
/// Subclassed by the preview support so the canvas can serve fixtures
/// without an extension.
@Observable
@MainActor
class TunnelVaultClient {

    @ObservationIgnored private var connection: NSXPCConnection?

    @ObservationIgnored private let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS",
        category: "vault-client"
    )

    init() {}

    // MARK: - Connection lifecycle

    private func connect() {
        guard connection == nil else { return }

        let conn = NSXPCConnection(machServiceName: TunnelVaultService.machServiceName, options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: TunnelVaultDaemonProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
            }
        }
        conn.resume()
        connection = conn
    }

    private func proxy(
        _ onError: @escaping @Sendable (Error) -> Void
    ) -> TunnelVaultDaemonProtocol? {
        if connection == nil { connect() }
        guard let conn = connection else { return nil }
        return conn.remoteObjectProxyWithErrorHandler(onError) as? TunnelVaultDaemonProtocol
    }

    // MARK: - RPCs

    /// Hands a tunnel's configuration to the extension for custody.
    /// Returns `false` on encode or transport failure — callers must
    /// treat that as "the tunnel was not saved".
    @discardableResult
    func store(_ config: TunnelConfig) async -> Bool {
        guard let payload = try? JSONEncoder().encode(config) else {
            os_log("store — encode FAILED", log: log, type: .error)
            return false
        }
        let id = config.id.uuidString

        return await withRaceTimeout("store", seconds: 5, fallback: false) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("store error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(false)
                }) else {
                    resume.finish(false)
                    return
                }
                proxy.storeVault(payload, id: id) { ok in resume.finish(ok) }
            }
        }
    }

    /// The tunnel's configuration, or `nil` when the vault has no
    /// payload for it (deleted out of band, or written by a build that
    /// predates custody).
    func fetch(id: UUID) async -> TunnelConfig? {
        let key = id.uuidString

        let payload: Data? = await withRaceTimeout("fetch", seconds: 5, fallback: nil) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("fetch error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(nil)
                }) else {
                    resume.finish(nil)
                    return
                }
                proxy.fetchVault(id: key) { data in resume.finish(data) }
            }
        }

        guard let payload else {
            os_log("fetch — vault holds no payload for %{public}@", log: log, type: .default, key)
            return nil
        }
        return try? JSONDecoder().decode(TunnelConfig.self, from: payload)
    }

    @discardableResult
    func delete(id: UUID) async -> Bool {
        let key = id.uuidString

        return await withRaceTimeout("delete", seconds: 5, fallback: false) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("delete error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(false)
                }) else {
                    resume.finish(false)
                    return
                }
                proxy.deleteVault(id: key) { ok in resume.finish(ok) }
            }
        }
    }

    /// Every configuration the vault holds. The vault outlives the
    /// system's NetworkExtension preferences — macOS drops a tunnel's
    /// configuration when its provider extension is uninstalled — so
    /// this is what the recovery pass reads to find payloads whose
    /// system entry is gone.
    func fetchAll() async -> [TunnelConfig] {
        let payloads: [Data]? = await withRaceTimeout("fetchAll", seconds: 5, fallback: nil) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<[Data]?, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("fetchAll error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(nil)
                }) else {
                    resume.finish(nil)
                    return
                }
                proxy.fetchAllVaults { data in resume.finish(data) }
            }
        }

        // A payload only counts once it decodes — that is the gate for
        // recreating anything. Undecodable ones are reported rather
        // than dropped in silence: they still occupy the vault, and a
        // sudden count is the signal that a schema moved underneath us.
        var configs: [TunnelConfig] = []
        var undecodable = 0
        for payload in payloads ?? [] {
            if let config = try? JSONDecoder().decode(TunnelConfig.self, from: payload) {
                configs.append(config)
            } else {
                undecodable += 1
            }
        }

        os_log("fetchAll — %{public}d usable payload(s)", log: log, type: .default, configs.count)
        if undecodable > 0 {
            os_log("fetchAll — %{public}d payload(s) FAILED to decode and were ignored",
                   log: log, type: .error, undecodable)
        }
        return configs
    }

    // MARK: - Race-Timeout Helper

    /// Race an async operation against a sleep; first to finish wins.
    /// The losing side keeps running — `NSXPCConnection` RPCs aren't
    /// cancellable from Swift — but its eventual result is dropped.
    /// A timeout win is logged: without that line an extension that
    /// never answers is indistinguishable from an empty vault.
    private func withRaceTimeout<T: Sendable>(
        _ label: String,
        seconds: Double,
        fallback: T,
        operation: @escaping @MainActor () async -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let resume = SingleResume(continuation)
            Task { @MainActor in
                let result = await operation()
                resume.finish(result)
            }
            Task { [log] in
                try? await Task.sleep(for: .seconds(seconds))
                if resume.finish(fallback) {
                    os_log("%{public}@ TIMED OUT after %{public}.0fs — extension unreachable",
                           log: log, type: .error, label, seconds)
                }
            }
        }
    }
}

/// Guards a continuation that several callbacks may reach — the XPC
/// error handler and the reply block both fire in some failure modes,
/// and resuming twice traps.
private final class SingleResume<T>: @unchecked Sendable {
    private let continuation: CheckedContinuation<T, Never>
    private let lock = NSLock()
    private var done = false

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    /// `true` when this call is the one that resumed — lets the
    /// timeout branch tell "I won" from "I was already beaten".
    @discardableResult
    func finish(_ value: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        continuation.resume(returning: value)
        return true
    }
}
