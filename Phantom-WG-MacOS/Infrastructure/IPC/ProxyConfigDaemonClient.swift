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
            let resume = SingleResume(continuation)
            let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
                os_log("applyConfig error: %{public}@",
                       log: self?.log ?? OSLog.default, type: .error, error.localizedDescription)
                resume.finish(false)
            } as? ProxyConfigDaemonProtocol

            guard let proxy else {
                resume.finish(false)
                return
            }
            proxy.applyConfig(data) { success in
                resume.finish(success)
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

    /// The extension's build identity, or `nil` when the daemon does
    /// not answer — an old extension that predates the RPC, a missing
    /// extension, or a transport failure all land there; the gate's
    /// fallback tree tells them apart via properties. 5s timeout.
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

    /// Race an async operation against a sleep; first to finish wins.
    /// The losing side keeps running — `NSXPCConnection` RPCs aren't
    /// cancellable from Swift — but its eventual result is dropped.
    private func withRaceTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        operation: @escaping () async -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            // The hand-rolled lock-and-flag this used to carry is the
            // shared `SingleResume` now: same one-shot guarantee, but
            // the flag lives inside a `Mutex`, so the type is Sendable
            // by compiler proof instead of by inspection. Its twin in
            // the vault client retired for the same reason.
            let resume = SingleResume(continuation)
            Task { resume.finish(await operation()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                resume.finish(fallback)
            }
        }
    }
}
