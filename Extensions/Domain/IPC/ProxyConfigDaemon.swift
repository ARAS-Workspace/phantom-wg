import Foundation
import os.log

protocol ProxyConfigReceiver: AnyObject {
    func applyConfiguration(_ configuration: SplitTunnelingConfiguration)
}

final class ProxyConfigDaemon: NSObject, NSXPCListenerDelegate, ProxyConfigDaemonProtocol {

    static var shared: ProxyConfigDaemon?

    private static let peerCodeRequirement =
        #"anchor apple generic and certificate leaf[subject.OU] = "9C5SL5H7CM""#

    private let listener: NSXPCListener
    private let log: OSLog
    private(set) var isStarted = false

    private weak var provider: ProxyConfigReceiver?

    private var pendingConfig: SplitTunnelingConfiguration?

    private let pendingLock = NSLock()

    private let deliveryQueue: DispatchQueue

    init(machServiceName: String, subsystem: String) {
        self.listener = NSXPCListener(machServiceName: machServiceName)
        self.log = OSLog(subsystem: subsystem, category: "proxy-daemon")
        self.deliveryQueue = DispatchQueue(label: "\(subsystem).proxy-daemon.delivery")
        super.init()
        self.listener.delegate = self
    }

    // MARK: - Provider lifecycle

    func attach(provider: ProxyConfigReceiver) {
        pendingLock.lock()
        self.provider = provider
        let pending = pendingConfig
        pendingConfig = nil
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

    func detach() {
        pendingLock.lock()
        self.provider = nil
        pendingConfig = nil
        pendingLock.unlock()
        RingBufferLogger.shared.clear()
        os_log("provider detached, log buffer cleared", log: log, type: .default)
    }

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

    func applyConfig(_ data: Data, reply: @escaping (Bool) -> Void) {
        os_log("RPC applyConfig (%{public}d bytes)", log: log, type: .default, data.count)

        let config: SplitTunnelingConfiguration
        do {
            config = try JSONDecoder().decode(SplitTunnelingConfiguration.self, from: data)
        } catch {
            os_log("applyConfig — decode FAILED: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            reply(false)
            return
        }

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
