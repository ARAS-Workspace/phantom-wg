import Foundation
import os.log

/// In-process XPC server that lets the host app read and write the
/// tunnel vault it cannot touch directly. Started at extension boot,
/// before any provider exists, so the app can store a tunnel's secrets
/// at import time — long before that tunnel is ever activated. launchd
/// spawns this extension on demand when the app connects, keyed off
/// the Info.plist `NEMachServiceName`.
///
/// The RPCs are pure custody: they move payloads in and out of
/// `SystemKeychainVault` and never touch the running tunnel. The
/// provider reads the vault directly, in-process, at `startTunnel`.
///
/// Every connection gets its own endpoint bound to the caller's uid,
/// taken from the kernel rather than from anything the peer sends, so
/// one login account cannot reach another's tunnels through the
/// machine-wide System keychain.
final class TunnelVaultDaemon: NSObject, NSXPCListenerDelegate {

    /// Process-local singleton, assigned by `main.swift`.
    static var shared: TunnelVaultDaemon?

    /// Peers must be signed by our own team. Enforced off the kernel
    /// audit token — race-free and immune to the PID-reuse window a
    /// manual processIdentifier check carries. Set before `resume()`.
    private static let peerCodeRequirement =
        #"anchor apple generic and certificate leaf[subject.OU] = "9C5SL5H7CM""#

    private let listener: NSXPCListener
    private let log: OSLog
    private var isStarted = false

    init(machServiceName: String, subsystem: String) {
        self.listener = NSXPCListener(machServiceName: machServiceName)
        self.log = OSLog(subsystem: subsystem, category: "vault-daemon")
        super.init()
        self.listener.delegate = self
    }

    /// Resume the listener. Idempotent. Must run before any client
    /// attempts a connection.
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

        // Pin the peer to our own team's signature. The Mach service is
        // registered under an application-group name, so any local
        // process can look it up — and these RPCs hand out tunnel
        // private keys. An unverified peer would be a key-exfiltration
        // primitive.
        newConnection.setCodeSigningRequirement(Self.peerCodeRequirement)
        os_log("accepting connection pid=%{public}d uid=%{public}d (requirement pinned)",
               log: log, type: .default, pid, owner)

        newConnection.exportedInterface = NSXPCInterface(with: TunnelVaultDaemonProtocol.self)
        newConnection.exportedObject = TunnelVaultEndpoint(owner: owner, log: log)
        newConnection.resume()
        return true
    }
}

/// One connection's view of the vault, fixed to the uid the kernel
/// reported for that connection.
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

    func fetchVault(id: String, reply: @escaping (Data?) -> Void) {
        os_log("RPC fetchVault (uid=%{public}d)", log: log, type: .default, owner)
        reply(SystemKeychainVault.fetch(id: id, owner: owner))
    }

    func deleteVault(id: String, reply: @escaping (Bool) -> Void) {
        os_log("RPC deleteVault (uid=%{public}d)", log: log, type: .default, owner)
        reply(SystemKeychainVault.delete(id: id, owner: owner))
    }

    func fetchAllVaults(reply: @escaping ([Data]?) -> Void) {
        let payloads = SystemKeychainVault.fetchAll(owner: owner)
        os_log("RPC fetchAllVaults (uid=%{public}d) -> %{public}d",
               log: log, type: .default, owner, payloads.count)
        reply(payloads.isEmpty ? nil : payloads)
    }

    func purgeVault(reply: @escaping (Bool) -> Void) {
        os_log("RPC purgeVault (uid=%{public}d)", log: log, type: .default, owner)
        reply(SystemKeychainVault.purge(owner: owner))
    }
}
