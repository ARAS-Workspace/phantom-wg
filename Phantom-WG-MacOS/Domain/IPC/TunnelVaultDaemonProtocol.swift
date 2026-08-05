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

    /// Returns the tunnel's vault payload. The second argument is
    /// `false` when the vault itself could not answer — treat that
    /// like an unreachable vault, never like an absent item. A `nil`
    /// payload alongside `true` means the vault truly holds nothing
    /// for that id.
    func fetchVault(id: String, reply: @escaping (Data?, Bool) -> Void)

    /// Drops the tunnel's vault item. Replies `true` when the item is
    /// gone, including when it was already absent.
    func deleteVault(id: String, reply: @escaping (Bool) -> Void)

    /// Every payload the vault holds — what the app's reconcile pass
    /// compares the system's NetworkExtension preferences against.
    /// An empty vault answers `[]`; `nil` means the enumeration
    /// failed and the caller knows nothing.
    func fetchAllVaults(reply: @escaping ([Data]?) -> Void)

    /// Deletes every payload the caller owns. The uninstall flow runs
    /// this before deactivating the extensions, while there is still a
    /// peer to ask.
    func purgeVault(reply: @escaping (Bool) -> Void)

    /// Session and identity probe in one endpoint — launchd waking
    /// this extension answers the call at all, the identity is the
    /// extension's `ExtensionIdentity.current` (what the gate compares
    /// before deciding an activation is needed), the Bool is the vault
    /// door check, and the count is how many payloads the caller owns.
    /// No secret material moves. One RPC serves both locks so the
    /// launch path never asks the same daemon twice.
    func pingIdentity(reply: @escaping (String, Bool, Int) -> Void)

}

/// Mach service the tunnel extension vends. Like the proxy services it
/// must literally begin with one of the `application-groups`
/// entitlement entries, and the Info.plist `NEMachServiceName` carries
/// the byte-identical string so launchd can spawn the extension on
/// demand when the app connects.
public enum TunnelVaultService {
    public static let machServiceName = "group.com.remrearas.phantom-wg-macos.tunnelvault"
}
