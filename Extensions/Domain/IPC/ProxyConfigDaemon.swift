import Foundation
import os.log

/// A provider that accepts live split-tunneling configuration. Both
/// PhantomDNSProxy and PhantomSplitTunnel conform, so one daemon can
/// drive either.
protocol ProxyConfigReceiver: AnyObject {
    func applyConfiguration(_ configuration: SplitTunnelingConfiguration)
}

/// In-process XPC server hosted by a lazy-spawned proxy extension.
/// Started at extension boot — before the OS spawns the provider on the
/// first flow — so the host app can push configuration into the daemon,
/// which buffers it and replays it the moment the provider attaches.
///
/// One instance per extension process, reachable via `shared`. Because
/// each extension is its own process that static is unambiguous; the
/// DNSProxy and SplitTunnel extensions use this same class, each with
/// its own Mach service name.
final class ProxyConfigDaemon: NSObject, NSXPCListenerDelegate, ProxyConfigDaemonProtocol {

    /// Process-local singleton, assigned by each extension's `main.swift`.
    static var shared: ProxyConfigDaemon?

    /// Peers must be signed by our own team. Enforced off the kernel
    /// audit token — race-free and immune to the PID-reuse window a
    /// manual processIdentifier check carries. Set before `resume()`.
    private static let peerCodeRequirement =
        #"anchor apple generic and certificate leaf[subject.OU] = "9C5SL5H7CM""#

    private let listener: NSXPCListener
    private let log: OSLog
    private(set) var isStarted = false

    /// Live provider attached at `startProxy`. Weak so `stopProxy`
    /// leaves no dangling pointer.
    private weak var provider: ProxyConfigReceiver?

    /// Payload buffered while no provider was attached (lazy-spawn
    /// window). Replayed at the next `attach()`.
    private var pendingConfig: Data?
    private let pendingLock = NSLock()

    init(machServiceName: String, subsystem: String) {
        self.listener = NSXPCListener(machServiceName: machServiceName)
        self.log = OSLog(subsystem: subsystem, category: "proxy-daemon")
        super.init()
        self.listener.delegate = self
    }

    // MARK: - Provider lifecycle

    /// Drains any config buffered during the lazy-spawn window so the
    /// provider boots with the live App-pushed payload.
    func attach(provider: ProxyConfigReceiver) {
        self.provider = provider
        os_log("provider attached", log: log, type: .default)

        pendingLock.lock()
        let data = pendingConfig
        pendingConfig = nil
        pendingLock.unlock()

        guard let data else { return }
        do {
            let config = try JSONDecoder().decode(SplitTunnelingConfiguration.self, from: data)
            provider.applyConfiguration(config)
            os_log("attach: drained pending config — apps=%{public}d",
                   log: log, type: .default, config.apps.count)
        } catch {
            os_log("attach: pending config decode FAILED — %{public}@",
                   log: log, type: .error, error.localizedDescription)
        }
    }

    /// Drops the provider reference and clears the log buffer so the
    /// next session starts with a fresh log surface.
    func detach() {
        self.provider = nil
        pendingLock.lock()
        pendingConfig = nil
        pendingLock.unlock()
        RingBufferLogger.shared.clear()
        os_log("provider detached, log buffer cleared", log: log, type: .default)
    }

    /// Resume the listener. Idempotent. Must run before any client
    /// attempts a connection.
    func start() {
        guard !isStarted else {
            os_log("start() already started, skipping", log: log, type: .default)
            return
        }
        listener.resume()
        isStarted = true
        os_log("daemon listening", log: log, type: .default)
    }

    func stop() {
        guard isStarted else { return }
        listener.invalidate()
        isStarted = false
        os_log("daemon stopped", log: log, type: .default)
    }

    // MARK: - NSXPCListenerDelegate

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let pid = newConnection.processIdentifier

        // Pin the peer to our own team's signature. The Mach service is
        // registered under an application-group name, so any local
        // process can look it up — and applyConfig() rewrites the
        // split-tunnel exclude list, i.e. which flows leave the VPN. An
        // unverified peer would be a tunnel-bypass primitive.
        newConnection.setCodeSigningRequirement(Self.peerCodeRequirement)
        os_log("accepting connection pid=%{public}d (requirement pinned)",
               log: log, type: .default, pid)

        newConnection.exportedInterface = NSXPCInterface(with: ProxyConfigDaemonProtocol.self)
        newConnection.exportedObject = self
        newConnection.invalidationHandler = { [weak self] in
            os_log("connection invalidated pid=%{public}d",
                   log: self?.log ?? OSLog.default, type: .default, pid)
        }
        newConnection.interruptionHandler = { [weak self] in
            os_log("connection interrupted pid=%{public}d",
                   log: self?.log ?? OSLog.default, type: .default, pid)
        }
        newConnection.resume()
        return true
    }

    // MARK: - ProxyConfigDaemonProtocol

    /// Buffers the payload when no provider is attached (lazy-spawn
    /// window) and replies `true` so the App's client considers the
    /// push successful — `attach` drains the buffer before the provider
    /// sees its first flow.
    func applyConfig(_ data: Data, reply: @escaping (Bool) -> Void) {
        os_log("RPC applyConfig (%{public}d bytes)", log: log, type: .default, data.count)

        guard let provider = provider else {
            pendingLock.lock()
            pendingConfig = data
            pendingLock.unlock()
            os_log("applyConfig — no provider yet, buffered for attach", log: log, type: .default)
            reply(true)
            return
        }

        do {
            let config = try JSONDecoder().decode(SplitTunnelingConfiguration.self, from: data)
            provider.applyConfiguration(config)
            os_log("applyConfig — applied apps=%{public}d", log: log, type: .default, config.apps.count)
            reply(true)
        } catch {
            os_log("applyConfig — decode FAILED: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            reply(false)
        }
    }

    func fetchLogs(reply: @escaping (Data?) -> Void) {
        let snapshot = RingBufferLogger.shared.snapshot()
        reply(snapshot.isEmpty ? nil : snapshot.data(using: .utf8))
    }

    func clearLogs(reply: @escaping (Bool) -> Void) {
        os_log("RPC clearLogs", log: log, type: .default)
        RingBufferLogger.shared.clear()
        reply(true)
    }
}
