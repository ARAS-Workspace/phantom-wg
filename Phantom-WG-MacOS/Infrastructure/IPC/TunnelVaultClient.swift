import Foundation
import Observation
import os.log

protocol VaultAnswerable {
    var isAnswer: Bool { get }
}

@Observable
@MainActor
class TunnelVaultClient {

    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var lastLoggedUsableCount: Int?
    private static let darkWindow: TimeInterval = 2
    @ObservationIgnored private var darkUntil: Date?
    @ObservationIgnored private var sparedWhileDark = 0

    @ObservationIgnored private let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS",
        category: "vault-client"
    )

    init() {}

    deinit {
        connection?.invalidate()
    }

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

    private func discardProvenSilence() {
        darkUntil = nil
    }

    #if DEBUG
    func armProvenSilenceForTesting() {
        darkUntil = Date().addingTimeInterval(Self.darkWindow)
    }

    var hasProvenSilence: Bool {
        guard let darkUntil else { return false }
        return Date() < darkUntil
    }

    private(set) var darkWindowAnswersTotal = 0
    #endif

    private func proxy(
        _ onError: @escaping @Sendable (Error) -> Void
    ) -> TunnelVaultDaemonProtocol? {
        if connection == nil { connect() }
        guard let conn = connection else { return nil }
        return conn.remoteObjectProxyWithErrorHandler(onError) as? TunnelVaultDaemonProtocol
    }

    // MARK: - RPCs

    enum Write: Equatable, VaultAnswerable {
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

        var isAnswer: Bool { self != .unreachable }
    }

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

    @discardableResult
    func store(_ config: TunnelConfig, attempts: Int) async -> Write {
        var outcome = Write.unreachable
        for attempt in 1...max(1, attempts) {
            if Task.isCancelled { return outcome }
            outcome = await store(config)
            if outcome == .done { return outcome }
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(600 * attempt))
                if Task.isCancelled { return outcome }
                discardProvenSilence()
            }
        }
        return outcome
    }

    enum Read {
        case config(TunnelConfig)
        case missing
        case undecodable
        case unreachable
    }

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
                if Task.isCancelled { return result }
                discardProvenSilence()
            }
        }

        return result
    }

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

    @discardableResult
    func delete(id: UUID, attempts: Int) async -> Write {
        var outcome = Write.unreachable
        for attempt in 1...max(1, attempts) {
            if Task.isCancelled { return outcome }
            outcome = await delete(id: id)
            if outcome == .done { return outcome }
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(600 * attempt))
                if Task.isCancelled { return outcome }
                discardProvenSilence()
            }
        }
        return outcome
    }

    enum Ping: VaultAnswerable {
        case ready(payloads: Int, identity: String)
        case doorFailed(identity: String)
        case unreachable

        var isAnswer: Bool { if case .unreachable = self { false } else { true } }
    }

    func ping() async -> Ping {
        await withRaceTimeout("ping", seconds: 5, fallback: .unreachable, honouringDarkWindow: false) { [log] in
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

    enum ReadAll {
        case configs([TunnelConfig])
        case unreachable
    }

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

        var configs: [TunnelConfig] = []
        var undecodable = 0
        for payload in payloads {
            if let config = try? JSONDecoder().decode(TunnelConfig.self, from: payload) {
                configs.append(config)
            } else {
                undecodable += 1
            }
        }

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

    private func withRaceTimeout<T: Sendable & VaultAnswerable>(
        _ label: String,
        seconds: Double,
        fallback: T,
        honouringDarkWindow: Bool = true,
        operation: @escaping @MainActor () async -> T
    ) async -> T {
        if honouringDarkWindow, let darkUntil, Date() < darkUntil {
            sparedWhileDark += 1
            #if DEBUG
            darkWindowAnswersTotal += 1
            #endif
            return fallback
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let resume = SingleResume(continuation)
            Task { @MainActor in
                let result = await operation()
                if resume.finish(result), result.isAnswer {
                    self.darkUntil = nil
                    self.sparedWhileDark = 0
                }
            }
            Task { @MainActor [log] in
                try? await Task.sleep(for: .seconds(seconds))
                guard resume.finish(fallback) else { return }
                let spared = self.sparedWhileDark
                self.darkUntil = Date().addingTimeInterval(Self.darkWindow)
                self.sparedWhileDark = 0
                if spared > 0 {
                    os_log("""
                           %{public}@ TIMED OUT after %{public}.0fs — extension unreachable \
                           (%{public}d call(s) answered from the dark window since the last timeout)
                           """,
                           log: log, type: .error, label, seconds, spared)
                } else {
                    os_log("%{public}@ TIMED OUT after %{public}.0fs — extension unreachable",
                           log: log, type: .error, label, seconds)
                }
            }
        }
    }
}

private enum RawRead: VaultAnswerable {
    case payload(Data)
    case empty
    case failed
    case unreachable

    var isAnswer: Bool { if case .unreachable = self { false } else { true } }
}

private enum RawReadAll: VaultAnswerable {
    case payloads([Data])
    case failed
    case unreachable

    var isAnswer: Bool { if case .unreachable = self { false } else { true } }
}
