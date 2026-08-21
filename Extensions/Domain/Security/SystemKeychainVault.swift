import Foundation
import Security
import os.log

enum SystemKeychainVault {

    static let service = "com.remrearas.Phantom-WG-MacOS.tunnelvault"

    private static let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomTunnel",
        category: "vault"
    )

    private static let lock = NSLock()

    enum FetchResult {
        case payload(Data)
        case missing
        case failed
    }

    // MARK: - CRUD

    @discardableResult
    static func store(_ payload: Data, id: String, owner: uid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        switch ownerOf(id: id) {
        case .stamped(let existing) where existing != owner:
            report("store(denied — owned by \(existing))", id: id, status: errSecAuthFailed)
            return false
        case .unstamped:
            report("store(denied — unowned slot)", id: id, status: errSecAuthFailed)
            return false
        case .failed:
            return false
        case .stamped, .absent:
            break
        }

        let fields: [String: Any] = [
            kSecAttrDescription as String: String(owner),
            kSecAttrLabel as String: "Phantom-WG Tunnel (\(id))",
            kSecValueData as String: payload
        ]

        var status = SecItemUpdate(query(id: id) as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(id: id)
            fields.forEach { attributes[$0.key] = $0.value }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        report("store", id: id, status: status)
        return status == errSecSuccess
    }

    static func fetch(id: String, owner: uid_t) -> FetchResult {
        lock.lock()
        defer { lock.unlock() }

        switch ownerOf(id: id) {
        case .stamped(let existing) where existing != owner:
            report("fetch(denied — not the owner)", id: id, status: errSecItemNotFound)
            return .missing
        case .unstamped:
            report("fetch(denied — unowned slot)", id: id, status: errSecItemNotFound)
            return .missing
        case .failed:
            return .failed
        case .stamped, .absent:
            return payload(for: id)
        }
    }

    static func fetchForProvider(id: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard case .payload(let data) = payload(for: id) else { return nil }
        return data
    }

    @discardableResult
    static func delete(id: String, owner: uid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        switch ownerOf(id: id) {
        case .absent:
            return true
        case .unstamped:
            report("delete(denied — unowned slot)", id: id, status: errSecAuthFailed)
            return false
        case .stamped(let existing) where existing != owner:
            report("delete(denied — owned by \(existing))", id: id, status: errSecAuthFailed)
            return false
        case .failed:
            return false
        case .stamped:
            break
        }

        let status = SecItemDelete(query(id: id) as CFDictionary)
        report("delete", id: id, status: status)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func fetchAll(owner: uid_t) -> [Data]? {
        lock.lock()
        defer { lock.unlock() }

        guard let accounts = accounts(of: owner) else { return nil }
        var payloads: [Data] = []
        for account in accounts {
            switch payload(for: account) {
            case .payload(let data):
                payloads.append(data)
            case .missing:
                continue
            case .failed:
                return nil
            }
        }
        return payloads
    }

    static func purge(owner: uid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let accounts = accounts(of: owner) else { return false }

        var clean = true
        for account in accounts {
            let status = SecItemDelete(query(id: account) as CFDictionary)
            report("purge", id: account, status: status)
            if status != errSecSuccess && status != errSecItemNotFound {
                clean = false
            }
        }
        return clean
    }

    static func count(owner: uid_t) -> Int? {
        lock.lock()
        defer { lock.unlock() }

        return accounts(of: owner)?.count
    }

    // MARK: - Private

    private enum OwnerLookup {
        case stamped(uid_t)
        case absent
        case unstamped
        case failed
    }

    private static func ownerOf(id: String) -> OwnerLookup {
        var request = query(id: id)
        request[kSecReturnAttributes as String] = true

        var out: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &out)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return .absent }
            report("ownerOf", id: id, status: status)
            return .failed
        }
        guard let attributes = out as? [String: Any],
              let raw = attributes[kSecAttrDescription as String] as? String,
              let owner = uid_t(raw),
              String(owner) == raw else {
            return .unstamped
        }
        return .stamped(owner)
    }

    private static func accounts(of owner: uid_t) -> [String]? {
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]

        var out: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &out)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return [] }
            report("enumerate", id: "*", status: status)
            return nil
        }

        let mine = (out as? [[String: Any]] ?? []).filter {
            ($0[kSecAttrDescription as String] as? String) == String(owner)
        }

        var seen = Set<String>()
        return mine.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { seen.insert($0).inserted }
    }

    private static func payload(for id: String) -> FetchResult {
        var request = query(id: id)
        request[kSecReturnData as String] = true

        var out: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &out)
        report("fetch", id: id, status: status)
        guard let data = out as? Data else {
            return status == errSecItemNotFound ? .missing : .failed
        }
        return .payload(data)
    }

    private static func query(id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id
        ]
    }

    private static func report(_ operation: String, id: String, status: OSStatus) {
        guard status != errSecSuccess else {
            os_log("%{public}@ ok (id=%{public}@)", log: log, type: .default, operation, id)
            return
        }
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "?"
        os_log("%{public}@ FAILED (id=%{public}@) status=%{public}d %{public}@",
               log: log, type: .error, operation, id, status, text)
    }
}
