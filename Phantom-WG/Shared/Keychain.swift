import Foundation
import Security

/// Custody of tunnel secrets in the app-group Keychain — WireGuard's
/// persistent-reference pattern: the whole `TunnelConfig` JSON is
/// sealed into one item and only the opaque reference travels in
/// `providerConfiguration`, so secrets never sit in the NE
/// preferences. Items are written `kSecAttrAccessibleAfterFirstUnlock`
/// so the extension can read them for on-demand and post-reboot
/// starts. The access group is what lets the app write what the
/// extension later reads. Every write seals a new item; deleting an
/// item by its reference is the caller's (`TunnelsManager.add`,
/// `modify`, `remove`), and `deleteReferences(except:)` deletes the
/// items the system's entries do not reference
/// (`TunnelsManager.create`).
enum Keychain {

    private static let accessGroup = "group.com.artek.phantom-wg"
    private static let service = "com.artek.Phantom-WG"

    /// @witness Sanity.keychainRoundTrip
    static func openReference(called ref: Data) -> String? {
        var result: CFTypeRef?
        // Persistent reference already encodes the item identity —
        // no additional attributes needed (matches WireGuard approach)
        let status = SecItemCopyMatching([
            kSecValuePersistentRef: ref,
            kSecReturnData: true
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Seals `value` into a new item and returns its persistent reference.
    /// The account is `name` plus a fresh UUID, as WireGuard's iOS app
    /// writes it, so a replacement sits beside the item it replaces until
    /// the caller deletes one of the two.
    /// @witness Sanity.keychainRoundTrip
    /// @witness TunnelEdit.anAcceptedSaveLeavesOnlyTheItemItSealed
    @discardableResult
    static func makeReference(containing value: String, called name: String) -> Data? {
        guard let valueData = value.data(using: .utf8) else { return nil }

        var ref: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrLabel: name,
            kSecAttrAccount: name + ": " + UUID().uuidString,
            kSecAttrDescription: "Phantom-WG Tunnel Configuration",
            kSecAttrService: service,
            kSecAttrAccessGroup: accessGroup,
            kSecValueData: valueData,
            kSecReturnPersistentRef: true,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, &ref)
        guard status == errSecSuccess, let persistentRef = ref as? Data else { return nil }
        return persistentRef
    }

    /// @witness Sanity.keychainRoundTrip
    static func deleteReference(called ref: Data) {
        SecItemDelete([kSecValuePersistentRef: ref] as CFDictionary)
    }

    /// Deletes every item of this service and access group whose
    /// persistent reference is not among `kept`. Each kept reference is
    /// compared as given and in the form the Keychain hands back for its
    /// item (`canonicalReference`).
    /// @witness TunnelLoad.anItemNoEntryReferencesIsCollectedAtLaunch
    static func deleteReferences(except kept: Set<Data>) {
        let keptForms = kept.union(kept.compactMap(canonicalReference))
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccessGroup: accessGroup,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnPersistentRef: true
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let refs = result as? [Data] else { return }
        for ref in refs where !keptForms.contains(ref) {
            deleteReference(called: ref)
        }
    }

    /// The persistent reference the Keychain hands back for the item
    /// `ref` opens; `nil` when that item is not found.
    static func canonicalReference(_ ref: Data) -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecValuePersistentRef: ref,
            kSecReturnPersistentRef: true
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}
