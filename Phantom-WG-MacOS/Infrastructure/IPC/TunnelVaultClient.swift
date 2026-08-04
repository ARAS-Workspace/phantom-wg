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

    /// Outcome of a single read. The two failures are different
    /// stories and callers must not tell them the same way: the vault
    /// answering "no such payload" is final, while failing to reach
    /// the vault at all is usually a moment old — the extension is
    /// spawned on demand, and the first connection after it has been
    /// idle can lose the race.
    enum Read {
        case config(TunnelConfig)
        /// The vault answered and had nothing usable for this tunnel.
        case missing
        /// The vault could not be reached, or did not answer in time.
        case unreachable
    }

    /// One attempt. Overridden by the preview support.
    func read(id: UUID) async -> Read {
        let key = id.uuidString

        let raw: RawRead = await withRaceTimeout("fetch", seconds: 5, fallback: .unreachable) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<RawRead, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("fetch error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(.unreachable)
                }) else {
                    resume.finish(.unreachable)
                    return
                }
                proxy.fetchVault(id: key) { data in
                    resume.finish(data.map(RawRead.payload) ?? .empty)
                }
            }
        }

        switch raw {
        case .unreachable:
            return .unreachable
        case .empty:
            os_log("fetch — vault holds no payload for %{public}@", log: log, type: .default, key)
            return .missing
        case .payload(let data):
            guard let config = try? JSONDecoder().decode(TunnelConfig.self, from: data) else {
                os_log("fetch — payload for %{public}@ FAILED to decode", log: log, type: .error, key)
                return .missing
            }
            return .config(config)
        }
    }

    /// Reads, retrying only what is worth retrying. A vault that
    /// answers "missing" is believed the first time; one that cannot
    /// be reached is given a few more chances, spaced out, because
    /// waking the extension is what usually costs the first attempt.
    /// `onAttempt` reports each try so a view can show its progress,
    /// and cancelling the caller's task stops the loop — leaving the
    /// screen ends the retries with it.
    func read(
        id: UUID,
        attempts: Int,
        onAttempt: @MainActor @escaping (Int) -> Void = { _ in }
    ) async -> Read {
        var result = Read.unreachable

        for attempt in 1...max(1, attempts) {
            if Task.isCancelled { return result }
            onAttempt(attempt)

            result = await read(id: id)
            if case .unreachable = result {} else { return result }

            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(600 * attempt))
            }
        }

        return result
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

    /// Empties the vault — every payload this user owns. The uninstall
    /// flow calls it while the extension is still there to answer;
    /// `false` means the vault could not be reached or a deletion
    /// failed, and the caller must not treat the vault as clean.
    @discardableResult
    func purge() async -> Bool {
        await withRaceTimeout("purge", seconds: 5, fallback: false) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("purge error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(false)
                }) else {
                    resume.finish(false)
                    return
                }
                proxy.purgeVault { ok in resume.finish(ok) }
            }
        }
    }

    /// Outcome of reading the whole vault. As with a single read the
    /// two outcomes must stay apart, and here it matters far more: an
    /// empty answer means the vault owns nothing, while an unreachable
    /// vault means we know nothing at all. Reconcile deletes system
    /// entries the vault does not back, so mistaking the second for
    /// the first would wipe every tunnel on the machine.
    enum ReadAll {
        case configs([TunnelConfig])
        case unreachable
    }

    /// Every configuration the vault holds for this user. The vault
    /// outlives the system's NetworkExtension preferences — macOS
    /// drops a tunnel's configuration when its provider extension is
    /// uninstalled — so this is what reconcile compares against.
    func readAll() async -> ReadAll {
        let raw: RawReadAll = await withRaceTimeout("fetchAll", seconds: 5, fallback: .unreachable) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<RawReadAll, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("fetchAll error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(.unreachable)
                }) else {
                    resume.finish(.unreachable)
                    return
                }
                // The daemon answers `nil` for an empty vault, so the
                // reply block firing at all is what proves it spoke.
                proxy.fetchAllVaults { data in resume.finish(.payloads(data ?? [])) }
            }
        }

        guard case .payloads(let payloads) = raw else {
            return .unreachable
        }

        // A payload only counts once it decodes — that is the gate for
        // recreating anything. Undecodable ones are reported rather
        // than dropped in silence: they still occupy the vault, and a
        // sudden count is the signal that a schema moved underneath us.
        var configs: [TunnelConfig] = []
        var undecodable = 0
        for payload in payloads {
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
        return .configs(configs)
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

/// What came back over the wire, before it is interpreted: the reply
/// block firing with no data means the vault is empty, which is a very
/// different thing from the reply block never firing at all.
private enum RawRead {
    case payload(Data)
    case empty
    case unreachable
}

/// Same distinction for the bulk read: an answered-but-empty vault is
/// a fact, a silent one is an absence of facts.
private enum RawReadAll {
    case payloads([Data])
    case unreachable
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
