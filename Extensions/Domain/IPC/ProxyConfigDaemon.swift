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
    ///
    /// Guarded by `pendingLock`, the SAME lock as `pendingConfig`, and
    /// that pairing is the whole point. The two fields answer one
    /// question — "is there someone to hand this payload to, or does it
    /// wait?" — and reading one outside the lock that guards the other
    /// let both answers be no: `applyConfig` read this as nil on the
    /// XPC queue, `attach` set it and drained an empty buffer on the
    /// provider's thread, and only then did `applyConfig` store its
    /// payload, where nothing would ever look again. The app was told
    /// `true`.
    private weak var provider: ProxyConfigReceiver?

    /// Payload buffered while no provider was attached (lazy-spawn
    /// window). Replayed at the next `attach()`.
    ///
    /// Decoded rather than raw: `applyConfig` decodes at the door, so a
    /// payload that will not decode is refused there instead of being
    /// buffered and failing later at an `attach` whose caller has
    /// nowhere to report it.
    private var pendingConfig: SplitTunnelingConfiguration?

    /// Guards `provider` and `pendingConfig` together. `applyConfiguration`
    /// is never called while it is held — a provider is free to call back
    /// into this daemon, and holding the lock across that call is the one
    /// way to turn this fix into a deadlock.
    private let pendingLock = NSLock()

    /// Where deliveries actually run, one at a time.
    ///
    /// Pairing the two fields under one lock closed the window where a
    /// push fell BETWEEN the decision and the buffer. It left a second
    /// one open: both `attach` and `applyConfig` released the lock and
    /// only then called `applyConfiguration`, so two deliveries could be
    /// in flight with nothing deciding their order — the buffered
    /// payload from `attach` and a fresh push racing, and the extension
    /// keeping whichever landed last. A stale list winning that race is
    /// the same divergence the bootstrap blob repair exists to close,
    /// arriving by a different door.
    ///
    /// Enqueued while the lock is HELD and executed after it is
    /// released: the order deliveries run in is the order the lock
    /// admitted them, and `applyConfiguration` still never runs under
    /// it. `async` rather than `sync` for that second half — a `sync`
    /// here would hold the lock across the provider's call and rebuild
    /// the deadlock the lock's own doc warns about.
    private let deliveryQueue: DispatchQueue

    init(machServiceName: String, subsystem: String) {
        self.listener = NSXPCListener(machServiceName: machServiceName)
        self.log = OSLog(subsystem: subsystem, category: "proxy-daemon")
        self.deliveryQueue = DispatchQueue(label: "\(subsystem).proxy-daemon.delivery")
        super.init()
        self.listener.delegate = self
    }

    // MARK: - Provider lifecycle

    /// Drains any config buffered during the lazy-spawn window so the
    /// provider boots with the live App-pushed payload.
    func attach(provider: ProxyConfigReceiver) {
        // Publishing the provider and taking the buffer are ONE step.
        // Split apart, a push landing between them is stored after the
        // only reader has already looked.
        pendingLock.lock()
        self.provider = provider
        let pending = pendingConfig
        pendingConfig = nil
        // Enqueued here, under the lock, and not after it: a push that
        // takes the lock next queues BEHIND this one and the extension
        // ends on the newer list. Released first, the two orderings were
        // decided by the scheduler.
        if let pending {
            deliveryQueue.async { provider.applyConfiguration(pending) }
        }
        pendingLock.unlock()

        os_log("provider attached", log: log, type: .default)
        if let pending {
            os_log("attach: drained pending config — apps=%{public}d",
                   log: log, type: .default, pending.apps.count)
        }
    }

    /// Drops the provider reference and clears the log buffer so the
    /// next session starts with a fresh log surface.
    func detach() {
        pendingLock.lock()
        self.provider = nil
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

        // Decoded BEFORE the lock, which is also why the buffer holds a
        // configuration rather than bytes: decoding needs neither field,
        // and a payload that cannot be read must not take a delivery
        // slot or sit in a buffer whose eventual reader has no caller to
        // answer. This is the only place the wire is parsed.
        let config: SplitTunnelingConfiguration
        do {
            config = try JSONDecoder().decode(SplitTunnelingConfiguration.self, from: data)
        } catch {
            os_log("applyConfig — decode FAILED: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            reply(false)
            return
        }

        // One decision under one lock: either a provider is published
        // and this payload is queued for it, or there is none and it
        // becomes the buffer `attach` will drain. Deciding outside the
        // lock is what let a push fall between the two; ENQUEUING
        // outside it is what let two deliveries race.
        pendingLock.lock()
        let attached = provider
        if let attached {
            deliveryQueue.async { attached.applyConfiguration(config) }
        } else {
            pendingConfig = config
        }
        pendingLock.unlock()

        if attached == nil {
            os_log("applyConfig — no provider yet, buffered for attach", log: log, type: .default)
        } else {
            os_log("applyConfig — queued apps=%{public}d", log: log, type: .default, config.apps.count)
        }
        reply(true)
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

    func fetchIdentity(reply: @escaping (String) -> Void) {
        let identity = ExtensionIdentity.current
        os_log("RPC fetchIdentity -> %{public}@", log: log, type: .default, identity)
        reply(identity)
    }
}
