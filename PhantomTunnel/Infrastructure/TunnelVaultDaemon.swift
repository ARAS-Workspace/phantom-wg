import Foundation
import os.log

final class TunnelVaultDaemon: NSObject, NSXPCListenerDelegate {

    static var shared: TunnelVaultDaemon?

    private static let peerCodeRequirement =
        #"identifier "com.remrearas.Phantom-WG-MacOS" and anchor apple generic and certificate leaf[subject.OU] = "9C5SL5H7CM""#

    private let listener: NSXPCListener
    private let log: OSLog
    private var isStarted = false

    init(machServiceName: String, subsystem: String) {
        self.listener = NSXPCListener(machServiceName: machServiceName)
        self.log = OSLog(subsystem: subsystem, category: "vault-daemon")
        super.init()
        self.listener.delegate = self
    }

    func start() {
        guard !isStarted else { return }
        listener.resume()
        isStarted = true
        os_log("vault daemon listening", log: log, type: .default)
    }

    // MARK: - NSXPCListenerDelegate

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let pid = newConnection.processIdentifier
        let owner = newConnection.effectiveUserIdentifier

        newConnection.setCodeSigningRequirement(Self.peerCodeRequirement)
        os_log("accepting connection pid=%{public}d uid=%{public}d (requirement pinned)",
               log: log, type: .default, pid, owner)

        newConnection.exportedInterface = NSXPCInterface(with: TunnelVaultDaemonProtocol.self)
        newConnection.exportedObject = TunnelVaultEndpoint(owner: owner, log: log)
        newConnection.resume()
        return true
    }
}

private final class TunnelVaultEndpoint: NSObject, TunnelVaultDaemonProtocol {

    private let owner: uid_t
    private let log: OSLog

    init(owner: uid_t, log: OSLog) {
        self.owner = owner
        self.log = log
        super.init()
    }

    func storeVault(_ payload: Data, id: String, reply: @escaping (Bool) -> Void) {
        os_log("RPC storeVault (%{public}d bytes, uid=%{public}d)",
               log: log, type: .default, payload.count, owner)
        reply(SystemKeychainVault.store(payload, id: id, owner: owner))
    }

    func fetchVault(id: String, reply: @escaping (Data?, Bool) -> Void) {
        os_log("RPC fetchVault (uid=%{public}d)", log: log, type: .default, owner)
        switch SystemKeychainVault.fetch(id: id, owner: owner) {
        case .payload(let data):
            reply(data, true)
        case .missing:
            reply(nil, true)
        case .failed:
            reply(nil, false)
        }
    }

    func deleteVault(id: String, reply: @escaping (Bool) -> Void) {
        os_log("RPC deleteVault (uid=%{public}d)", log: log, type: .default, owner)
        reply(SystemKeychainVault.delete(id: id, owner: owner))
    }

    func fetchAllVaults(reply: @escaping ([Data]?) -> Void) {
        let payloads = SystemKeychainVault.fetchAll(owner: owner)
        if let payloads {
            os_log("RPC fetchAllVaults (uid=%{public}d) -> %{public}d",
                   log: log, type: .default, owner, payloads.count)
        } else {
            os_log("RPC fetchAllVaults (uid=%{public}d) FAILED to enumerate",
                   log: log, type: .error, owner)
        }
        reply(payloads)
    }

    func purgeVault(reply: @escaping (Bool) -> Void) {
        os_log("RPC purgeVault (uid=%{public}d)", log: log, type: .default, owner)
        reply(SystemKeychainVault.purge(owner: owner))
    }

    func pingIdentity(reply: @escaping (String, Bool, Int) -> Void) {
        let identity = ExtensionIdentity.current
        if let count = SystemKeychainVault.count(owner: owner) {
            os_log("RPC pingIdentity (uid=%{public}d) -> %{public}@, ready, %{public}d payload(s)",
                   log: log, type: .default, owner, identity, count)
            reply(identity, true, count)
        } else {
            os_log("RPC pingIdentity (uid=%{public}d) -> %{public}@, vault door FAILED",
                   log: log, type: .error, owner, identity)
            reply(identity, false, 0)
        }
    }
}
