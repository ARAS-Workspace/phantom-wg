import Foundation
import Security

/// Custody of tunnel secrets in the app-group Keychain — WireGuard's
/// persistent-reference pattern: the whole `TunnelConfig` JSON is
/// sealed into one item and only the opaque reference travels in
/// `providerConfiguration`, so secrets never sit in the NE
/// preferences. Items are written `kSecAttrAccessibleAfterFirstUnlock`
/// so the extension can read them for on-demand and post-reboot
/// starts. The access group is what lets the app write what the
/// extension later reads. Note: updates rewrite only the value, so an
/// item keeps the accessibility class it was created under.
enum Keychain {

    private static let accessGroup = "group.com.remrearas.phantom-wg"
    private static let service = "com.remrearas.Phantom-WG"

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

    @discardableResult
    static func makeReference(containing value: String, called name: String,
                              previouslyReferencedBy oldRef: Data? = nil) -> Data? {
        if let oldRef = oldRef {
            deleteReference(called: oldRef)
        }

        guard let valueData = value.data(using: .utf8) else { return nil }

        var ref: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrLabel: name,
            kSecAttrAccount: name,
            kSecAttrDescription: "Phantom-WG Tunnel Configuration",
            kSecAttrService: service,
            kSecAttrAccessGroup: accessGroup,
            kSecValueData: valueData,
            kSecReturnPersistentRef: true,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]

        var status = SecItemAdd(query as CFDictionary, &ref)

        if status == errSecDuplicateItem {
            // Update existing item
            let searchQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: name,
                kSecAttrAccessGroup: accessGroup
            ]
            let updateAttrs: [CFString: Any] = [
                kSecValueData: valueData
            ]
            SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)

            // Re-fetch persistent reference
            let fetchQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: name,
                kSecAttrAccessGroup: accessGroup,
                kSecReturnPersistentRef: true
            ]
            status = SecItemCopyMatching(fetchQuery as CFDictionary, &ref)
        }

        guard status == errSecSuccess, let persistentRef = ref as? Data else { return nil }
        return persistentRef
    }

    static func deleteReference(called ref: Data) {
        SecItemDelete([kSecValuePersistentRef: ref] as CFDictionary)
    }
}
