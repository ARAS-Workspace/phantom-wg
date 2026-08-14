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
    /// The last usable-payload count the fetchAll line reported, so it
    /// fires on TRANSITIONS rather than on every pass. `nil` means the
    /// next successful answer logs unconditionally — the initial
    /// baseline, and the first light after a dark window.
    @ObservationIgnored private var lastLoggedUsableCount: Int?

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

    /// Outcome of a single write. The old Bool collapsed two different
    /// stories into one `false`, and every call site paid for it with
    /// a verified-sounding claim over a reading that verified nothing:
    /// `.refused` is the daemon ANSWERING no — definitive, the state
    /// stands as it was — while `.unreachable` is no answer at all,
    /// where the write may even have LANDED with only its reply lost.
    /// Callers that report state must branch on the difference; a
    /// caller that only needs success compares `== .done`.
    enum Write: Equatable {
        case done
        case refused
        case unreachable

        var label: String {
            switch self {
            case .done: return "done"
            case .refused: return "refused"
            case .unreachable: return "unreachable"
            }
        }
    }

    /// Hands a tunnel's configuration to the extension for custody.
    /// An encode failure is a local, definitive no and answers
    /// `.refused`; transport-level silence answers `.unreachable`.
    @discardableResult
    func store(_ config: TunnelConfig) async -> Write {
        guard let payload = try? JSONEncoder().encode(config) else {
            os_log("store — encode FAILED", log: log, type: .error)
            return .refused
        }
        let id = config.id.uuidString

        return await withRaceTimeout("store", seconds: 5, fallback: .unreachable) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Write, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("store error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(.unreachable)
                }) else {
                    resume.finish(.unreachable)
                    return
                }
                proxy.storeVault(payload, id: id) { ok in resume.finish(ok ? .done : .refused) }
            }
        }
    }

    /// Stores with the same patience `read(id:attempts:)` gives reads.
    /// The vault listener lives in the tunnel extension process, so a
    /// mutation issued right after a tunnel deactivation can lose the
    /// teardown/respawn race on its first try — caught live by the
    /// in-app test engine (an import right after a deactivation failed
    /// its one-shot store). Both non-done outcomes are retried — a
    /// store is an idempotent upsert, so retrying a refusal is
    /// harmless and a respawn-window keychain door can open between
    /// attempts — and the LAST outcome is returned, typed, so the
    /// caller still learns how the final attempt ended. A cancelled
    /// task sends nothing further and answers the last completed
    /// attempt's outcome — `.unreachable` when nothing was sent.
    @discardableResult
    func store(_ config: TunnelConfig, attempts: Int) async -> Write {
        var outcome = Write.unreachable
        for attempt in 1...max(1, attempts) {
            if Task.isCancelled { return outcome }
            outcome = await store(config)
            if outcome == .done { return outcome }
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(600 * attempt))
            }
        }
        return outcome
    }

    /// Outcome of a single read. The two failures are different
    /// stories and callers must not tell them the same way: the vault
    /// answering "no such payload" is final, while failing to reach
    /// the vault at all is usually a moment old — the extension is
    /// spawned on demand, and the first connection after it has been
    /// idle can lose the race.
    enum Read {
        case config(TunnelConfig)
        /// The vault answered and holds no payload for this id — or
        /// none this user owns: the daemon serves another account's
        /// item as absence, so this is also the foreign verdict.
        case missing
        /// The vault holds a payload for this id, but it does not
        /// decode into a `TunnelConfig`. Distinct from `.missing` on
        /// purpose: `.missing` is the ownership verdict — not this
        /// user's — while this secret is present, just unreadable, so
        /// ingest must keep the row listed and uninstall must keep
        /// its entry. A custody problem to surface, not an absence to
        /// act on.
        case undecodable
        /// The vault could not be reached, did not answer in time, or
        /// answered that it could not look.
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
                proxy.fetchVault(id: key) { data, ok in
                    guard ok else {
                        resume.finish(.failed)
                        return
                    }
                    resume.finish(data.map(RawRead.payload) ?? .empty)
                }
            }
        }

        switch raw {
        case .unreachable:
            return .unreachable
        case .failed:
            os_log("fetch — the vault answered but could not read %{public}@",
                   log: log, type: .error, key)
            return .unreachable
        case .empty:
            os_log("fetch — vault holds no payload for %{public}@", log: log, type: .default, key)
            return .missing
        case .payload(let data):
            guard let config = try? JSONDecoder().decode(TunnelConfig.self, from: data) else {
                os_log("fetch — payload for %{public}@ FAILED to decode (present but unreadable)", log: log, type: .error, key)
                return .undecodable
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

    /// Deleting an absent id answers `.done` (idempotent); `.refused`
    /// is the daemon answering that the keychain would not give the
    /// item up, `.unreachable` is silence — where the delete may have
    /// landed with only its reply lost.
    @discardableResult
    func delete(id: UUID) async -> Write {
        let key = id.uuidString

        return await withRaceTimeout("delete", seconds: 5, fallback: .unreachable) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Write, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("delete error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(.unreachable)
                }) else {
                    resume.finish(.unreachable)
                    return
                }
                proxy.deleteVault(id: key) { ok in resume.finish(ok ? .done : .refused) }
            }
        }
    }

    /// Delete-by-id is idempotent the same way — see `store(_:attempts:)`
    /// for the retry-and-return-last contract.
    @discardableResult
    func delete(id: UUID, attempts: Int) async -> Write {
        var outcome = Write.unreachable
        for attempt in 1...max(1, attempts) {
            if Task.isCancelled { return outcome }
            outcome = await delete(id: id)
            if outcome == .done { return outcome }
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(600 * attempt))
            }
        }
        return outcome
    }

    /// Outcome of the session probe. Three stories the gate tells
    /// apart: the extension answering with a closed vault door is not
    /// the extension being asleep. Both answered arms carry the
    /// extension's build identity — an answer proves liveness whatever
    /// the door says, and the extension gate reads the identity off
    /// the same probe the vault session uses.
    enum Ping {
        case ready(payloads: Int, identity: String)
        /// The extension answered; the System keychain did not.
        case doorFailed(identity: String)
        /// No answer at all — the extension is not awake (yet).
        case unreachable
    }

    /// Session probe — wakes the extension through launchd if needed
    /// and proves the custody chain end to end. Single attempt;
    /// patience lives in `TunnelVaultSession`.
    func ping() async -> Ping {
        await withRaceTimeout("ping", seconds: 5, fallback: .unreachable) { [log] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Ping, Never>) in
                let resume = SingleResume(continuation)
                guard let proxy = self.proxy({ error in
                    os_log("ping error: %{public}@", log: log, type: .error, error.localizedDescription)
                    resume.finish(.unreachable)
                }) else {
                    resume.finish(.unreachable)
                    return
                }
                proxy.pingIdentity { identity, ready, count in
                    resume.finish(ready
                        ? .ready(payloads: count, identity: identity)
                        : .doorFailed(identity: identity))
                }
            }
        }
    }

    /// Outcome of reading the whole vault. As with a single read the
    /// two outcomes must stay apart, and here it matters far more: an
    /// empty answer means the vault owns nothing, while an unreachable
    /// or failing vault means we know nothing at all. The decoded set
    /// is the ownership evidence everything downstream scopes by —
    /// the ingest boundary, the slot classifier, reconcile's restores
    /// — and evidence that never arrived must not impersonate "this
    /// user owns nothing".
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
                // An empty vault answers `[]`. `nil` is the vault
                // saying it could not enumerate — the daemon spoke,
                // but taught nothing.
                proxy.fetchAllVaults { data in
                    resume.finish(data.map(RawReadAll.payloads) ?? .failed)
                }
            }
        }

        let payloads: [Data]
        switch raw {
        case .payloads(let answered):
            payloads = answered
        case .failed:
            os_log("fetchAll — the vault answered but could not enumerate",
                   log: log, type: .error)
            lastLoggedUsableCount = nil
            return .unreachable
        case .unreachable:
            lastLoggedUsableCount = nil
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

        // The steady state stays quiet. This funnel runs on every
        // refresh, verdict and reconcile pass, so an unchanged count
        // repeated is noise carrying nothing; the count's diagnostic
        // value — the custody and isolation field signal — lives in
        // its TRANSITIONS. So the line fires when the count moves,
        // once for the initial baseline, and again on the first
        // answer after a dark window (the reset above), while every
        // failure path keeps its own line unconditionally.
        if configs.count != lastLoggedUsableCount {
            os_log("fetchAll — %{public}d usable payload(s)", log: log, type: .default, configs.count)
            lastLoggedUsableCount = configs.count
        }
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

/// What came back over the wire, before it is interpreted. Absence
/// and failure stay apart the whole way down: an answered "nothing
/// here" is a fact, while a vault that answered "could not look"
/// teaches as little as one that never spoke.
private enum RawRead {
    case payload(Data)
    case empty
    case failed
    case unreachable
}

/// Same distinction for the bulk read: an answered-but-empty vault is
/// a fact, a failed or silent one is an absence of facts.
private enum RawReadAll {
    case payloads([Data])
    case failed
    case unreachable
}

// The one-shot continuation guard these races ride lives in
// Infrastructure/Concurrency/SingleResume.swift — shared with the
// tunnels manager's deadline helper and the DEBUG harness.
