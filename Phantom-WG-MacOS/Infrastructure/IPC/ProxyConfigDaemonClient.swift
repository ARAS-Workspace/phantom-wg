import Foundation
import Observation
import os.log

@Observable
@MainActor
class ProxyConfigDaemonClient {

    private let machServiceName: String
    private let log: OSLog

    @ObservationIgnored private var connection: NSXPCConnection?

    init(machServiceName: String) {
        self.machServiceName = machServiceName
        self.log = OSLog(subsystem: "com.remrearas.Phantom-WG-MacOS",
                         category: "proxy-daemon-client")
    }

    // MARK: - Connection lifecycle

    func connect() {
        guard connection == nil else { return }
        os_log("Connecting to %{public}@", log: log, type: .default, machServiceName)

        let conn = NSXPCConnection(machServiceName: machServiceName, options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: ProxyConfigDaemonProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                os_log("Connection invalidated", log: self?.log ?? OSLog.default, type: .default)
            }
        }
        conn.interruptionHandler = { [weak self] in
            os_log("Connection interrupted", log: self?.log ?? OSLog.default, type: .default)
        }
        conn.resume()
        connection = conn
    }

    // MARK: - RPCs

    enum Push: Equatable, Sendable {
        case done
        case refused
        case unreachable
        case notSent

        var label: String {
            switch self {
            case .done: return "done"
            case .refused: return "refused"
            case .unreachable: return "unreachable"
            case .notSent: return "not sent"
            }
        }
    }

    func applyConfig(_ configuration: SplitTunnelingConfiguration) async -> Push {
        await withRaceTimeout(seconds: 5, fallback: Push.unreachable) {
            await self.applyConfigRPC(configuration)
        }
    }

    private func applyConfigRPC(_ configuration: SplitTunnelingConfiguration) async -> Push {
        if connection == nil { connect() }
        guard let conn = connection else { return .unreachable }
        guard let data = try? JSONEncoder().encode(configuration) else {
            os_log("applyConfig — encode FAILED, nothing left the app", log: log, type: .error)
            return .notSent
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Push, Never>) in
            let resume = SingleResume(continuation)
            let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
                os_log("applyConfig error: %{public}@",
                       log: self?.log ?? OSLog.default, type: .error, error.localizedDescription)
                resume.finish(.unreachable)
            } as? ProxyConfigDaemonProtocol

            guard let proxy else {
                resume.finish(.unreachable)
                return
            }
            proxy.applyConfig(data) { accepted in
                resume.finish(accepted ? .done : .refused)
            }
        }
    }

    /// @witness SplitControlPlane.liveEditLandsOnBoth
    /// @adr 0003
    func fetchLogs() async -> String? {
        await withRaceTimeout(seconds: 5, fallback: nil) {
            await self.fetchLogsRPC()
        }
    }

    private func fetchLogsRPC() async -> String? {
        if connection == nil { connect() }
        guard let conn = connection else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let resume = SingleResume(continuation)
            let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
                os_log("fetchLogs error: %{public}@",
                       log: self?.log ?? OSLog.default, type: .error, error.localizedDescription)
                resume.finish(nil)
            } as? ProxyConfigDaemonProtocol

            guard let proxy else {
                resume.finish(nil)
                return
            }
            proxy.fetchLogs { data in
                guard let data else {
                    resume.finish(nil)
                    return
                }
                resume.finish(String(data: data, encoding: .utf8))
            }
        }
    }

    /// @witness Sanity.installedBuildMatches
    func identity() async -> String? {
        await withRaceTimeout(seconds: 5, fallback: nil) {
            await self.identityRPC()
        }
    }

    private func identityRPC() async -> String? {
        if connection == nil { connect() }
        guard let conn = connection else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let resume = SingleResume(continuation)
            let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
                os_log("fetchIdentity error: %{public}@",
                       log: self?.log ?? OSLog.default, type: .error, error.localizedDescription)
                resume.finish(nil)
            } as? ProxyConfigDaemonProtocol

            guard let proxy else {
                resume.finish(nil)
                return
            }
            proxy.fetchIdentity { identity in
                resume.finish(identity)
            }
        }
    }

    /// @witness SplitControlPlane.clearBothBuffers
    /// @adr 0003
    @discardableResult
    func clearLogs() async -> Bool {
        await withRaceTimeout(seconds: 2, fallback: false) {
            await self.clearLogsRPC()
        }
    }

    private func clearLogsRPC() async -> Bool {
        if connection == nil { connect() }
        guard let conn = connection else { return false }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resume = SingleResume(continuation)
            let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
                os_log("clearLogs error: %{public}@",
                       log: self?.log ?? OSLog.default, type: .error, error.localizedDescription)
                resume.finish(false)
            } as? ProxyConfigDaemonProtocol

            guard let proxy else {
                resume.finish(false)
                return
            }
            proxy.clearLogs { ok in
                resume.finish(ok)
            }
        }
    }

    // MARK: - Race-Timeout Helper

    private func withRaceTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        operation: @escaping () async -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let resume = SingleResume(continuation)
            Task { resume.finish(await operation()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                resume.finish(fallback)
            }
        }
    }
}
