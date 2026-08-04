import Foundation

/// XPC interface to the tunnel extension's secret custody. The app
/// cannot reach the System keychain itself — it is root-owned and the
/// app is a sandboxed user process — so every read and write of a
/// tunnel's secrets goes through the extension, which owns the vault.
///
/// Payloads are `TunnelConfig` JSON. The app keeps only identity
/// (id, name, createdAt, ghost flag) in `providerConfiguration`.
@objc public protocol TunnelVaultDaemonProtocol {

    /// Writes (or replaces) the vault item for a tunnel.
    func storeVault(_ payload: Data, id: String, reply: @escaping (Bool) -> Void)

    /// Returns the tunnel's vault payload, or `nil` when the vault has
    /// no item for that id.
    func fetchVault(id: String, reply: @escaping (Data?) -> Void)

    /// Drops the tunnel's vault item. Replies `true` when the item is
    /// gone, including when it was already absent.
    func deleteVault(id: String, reply: @escaping (Bool) -> Void)

    /// Every payload the vault holds — what the app's reconcile pass
    /// compares the system's NetworkExtension preferences against.
    func fetchAllVaults(reply: @escaping ([Data]?) -> Void)

    /// Deletes every payload the caller owns. The uninstall flow runs
    /// this before deactivating the extensions, while there is still a
    /// peer to ask.
    func purgeVault(reply: @escaping (Bool) -> Void)

}

/// Mach service the tunnel extension vends. Like the proxy services it
/// must literally begin with one of the `application-groups`
/// entitlement entries, and the Info.plist `NEMachServiceName` carries
/// the byte-identical string so launchd can spawn the extension on
/// demand when the app connects.
public enum TunnelVaultService {
    public static let machServiceName = "group.com.remrearas.phantom-wg-macos.tunnelvault"
}
