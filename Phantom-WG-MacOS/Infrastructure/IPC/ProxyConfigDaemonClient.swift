import Foundation
import Observation
import os.log

/// Host-app XPC client for a `ProxyConfigDaemon` inside a proxy system
/// extension. Pushes live `SplitTunnelingConfiguration` (`applyConfig`)
/// and polls / clears the daemon's log ring buffer. One instance per
/// proxy, distinguished by its Mach service name. The connection is
/// established lazily on the first RPC.
///
/// Concrete per-proxy subclasses (`DNSProxyDaemonClient`,
/// `SplitTunnelDaemonClient`) fix the Mach service name; the app injects
/// them into the SwiftUI environment as distinct types.
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

    /// Push a `SplitTunnelingConfiguration` to the proxy provider.
    /// Returns `false` on encode / transport failure. 5s timeout.
    @discardableResult
    func applyConfig(_ configuration: SplitTunnelingConfiguration) async -> Bool {
        await withRaceTimeout(seconds: 5, fallback: false) {
            await self.applyConfigRPC(configuration)
        }
    }

    private func applyConfigRPC(_ configuration: SplitTunnelingConfiguration) async -> Bool {
        if connection == nil { connect() }
        guard let conn = connection else { return false }
        guard let data = try? JSONEncoder().encode(configuration) else {
            os_log("applyConfig — encode FAILED", log: log, type: .error)
            return false
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
                os_log("applyConfig error: %{public}@",
                       log: self?.log ?? OSLog.default, type: .error, error.localizedDescription)
                continuation.resume(returning: false)
            } as? ProxyConfigDaemonProtocol

            guard let proxy else {
                continuation.resume(returning: false)
                return
            }
            proxy.applyConfig(data) { success in
                continuation.resume(returning: success)
            }
        }
    }

    /// Newline-joined UTF-8 dump of the daemon's log ring buffer, or
    /// `nil` if empty / unavailable. 5s timeout.
    func fetchLogs() async -> String? {
        await withRaceTimeout(seconds: 5, fallback: nil) {
            await self.fetchLogsRPC()
        }
    }

    private func fetchLogsRPC() async -> String? {
        if connection == nil { connect() }
        guard let conn = connection else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
                os_log("fetchLogs error: %{public}@",
                       log: self?.log ?? OSLog.default, type: .error, error.localizedDescription)
                continuation.resume(returning: nil)
            } as? ProxyConfigDaemonProtocol

            guard let proxy else {
                continuation.resume(returning: nil)
                return
            }
            proxy.fetchLogs { data in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }

    /// Flush the daemon's ring buffer. 2s timeout.
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
            let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
                os_log("clearLogs error: %{public}@",
                       log: self?.log ?? OSLog.default, type: .error, error.localizedDescription)
                continuation.resume(returning: false)
            } as? ProxyConfigDaemonProtocol

            guard let proxy else {
                continuation.resume(returning: false)
                return
            }
            proxy.clearLogs { ok in
                continuation.resume(returning: ok)
            }
        }
    }

    // MARK: - Race-Timeout Helper

    /// Race an async operation against a sleep; first to finish wins.
    /// The losing side keeps running — `NSXPCConnection` RPCs aren't
    /// cancellable from Swift — but its eventual result is dropped.
    private func withRaceTimeout<T>(
        seconds: Double,
        fallback: T,
        operation: @escaping () async -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let lock = NSLock()
            var resumed = false
            func resumeOnce(_ value: T) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            Task {
                let result = await operation()
                resumeOnce(result)
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                resumeOnce(fallback)
            }
        }
    }
}
