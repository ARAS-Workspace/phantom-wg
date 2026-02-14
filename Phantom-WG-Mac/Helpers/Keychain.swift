import Foundation
import Security

enum Keychain {

    private static let accessGroup = "group.com.remrearas.phantom-wg-mac"
    private static let service = "com.remrearas.Phantom-WG-Mac"

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
            kSecAttrDescription: "Phantom-WG Mac Tunnel Configuration",
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

    static func deleteAllReferences() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccessGroup: accessGroup
        ]
        SecItemDelete(query as CFDictionary)
    }
}
