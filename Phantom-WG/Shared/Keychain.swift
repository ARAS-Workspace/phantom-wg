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
/// item by its reference is the caller's (`TunnelsManager.modify`,
/// `remove`).
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
}
