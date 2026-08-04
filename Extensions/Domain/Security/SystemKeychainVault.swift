import Foundation
import Security
import os.log

/// Custody of tunnel secrets in the **file-based System keychain**.
///
/// This is the extension's own store: a system extension runs as root
/// with no user session, so the login and data-protection keychains
/// are unreachable to it (`errSecNotAvailable` / `errSecItemNotFound`)
/// — the System keychain is the one domain that answers. Apple DTS
/// recommends exactly this shape (host app → XPC → extension →
/// keychain, with `providerConfiguration` carrying no secrets), and it
/// is what Tailscale's standalone system extension ships.
///
/// One item per tunnel: `service` is fixed, `account` is the tunnel's
/// `configId`, and the payload is the whole `TunnelConfig` JSON —
/// WireGuard keys and the wstunnel secret live in the same vault, so
/// there is a single place where a tunnel's secrets exist.
///
/// The System keychain is machine-wide, not per-user, so every item
/// records the uid that created it and every operation is scoped to a
/// caller. Without that, one account's app could read, overwrite or
/// project another account's tunnels — the price of the one keychain
/// domain a system extension can reach.
///
/// Lookup is by attributes rather than a persistent reference: the
/// account already identifies the item, and an attribute query still
/// resolves after an item is deleted and rewritten (a stored reference
/// would dangle). Only the extension calls this type; the app reaches
/// it through `TunnelVaultDaemon` over XPC.
enum SystemKeychainVault {

    static let service = "com.remrearas.Phantom-WG-MacOS.tunnelvault"

    private static let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomTunnel",
        category: "vault"
    )

    /// Serializes keychain access — RPCs arrive on XPC queues while
    /// `startTunnel` reads in-process on its own thread.
    private static let lock = NSLock()

    // MARK: - CRUD

    /// Writes (or replaces) the vault item for `id`, stamped with the
    /// owning uid. Delete-then-add rather than `SecItemUpdate` so a
    /// partially written item can never survive a failed rewrite.
    @discardableResult
    static func store(_ payload: Data, id: String, owner: uid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let keychain = systemKeychain() else { return false }

        // Replacing someone else's item is not a write, it is a theft
        // of their slot. Ids are random so this should never happen;
        // refusing costs nothing and closes the case where it does.
        if let existing = ownerOf(id: id), existing != owner {
            report("store(denied — owned by \(existing))", id: id, status: errSecAuthFailed)
            return false
        }

        SecItemDelete(query(id: id) as CFDictionary)

        var attributes = query(id: id)
        attributes[kSecAttrDescription as String] = String(owner)
        attributes[kSecAttrLabel as String] = "Phantom-WG Tunnel (\(id))"
        attributes[kSecValueData as String] = payload
        attributes[kSecUseKeychain as String] = keychain

        let status = SecItemAdd(attributes as CFDictionary, nil)
        report("store", id: id, status: status)
        return status == errSecSuccess
    }

    static func fetch(id: String, owner: uid_t) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        _ = systemKeychain()

        guard ownerOf(id: id) == owner else {
            report("fetch(denied — not the owner)", id: id, status: errSecItemNotFound)
            return nil
        }
        return payload(for: id)
    }

    /// Unscoped read for the provider's own use at `startTunnel`.
    ///
    /// Ownership is a boundary policy, not a storage lock: it exists so
    /// one login account's app cannot reach another's tunnels over XPC.
    /// The provider is not a peer — it runs as root inside this
    /// extension and is starting whichever configuration macOS handed
    /// it, which the system already scoped to the session that owns it.
    /// Checking the uid here would only lock the extension out of the
    /// payloads it exists to use.
    static func fetchForProvider(id: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        _ = systemKeychain()
        return payload(for: id)
    }

    @discardableResult
    static func delete(id: String, owner: uid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        _ = systemKeychain()

        switch ownerOf(id: id) {
        case .none:
            // Already gone is success for the caller's purposes.
            return true
        case .some(let existing) where existing != owner:
            report("delete(denied — owned by \(existing))", id: id, status: errSecAuthFailed)
            return false
        default:
            break
        }

        let status = SecItemDelete(query(id: id) as CFDictionary)
        report("delete", id: id, status: status)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Every payload belonging to `owner`. The reconcile pass uses it
    /// to find tunnels whose system entry is gone — macOS drops a
    /// tunnel's NetworkExtension configuration when its provider
    /// extension is uninstalled, and the vault outlives that.
    static func fetchAll(owner: uid_t) -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        _ = systemKeychain()

        // Two passes on purpose: the file-based keychain rejects a
        // bulk query that asks for item *data* (`kSecMatchLimitAll`
        // with `kSecReturnData` answers errSecParam), so enumerate the
        // accounts first and then read each payload with the
        // single-item query that is known to work.
        guard let accounts = accounts(of: owner) else { return [] }
        return accounts.compactMap { payload(for: $0) }
    }

    /// Deletes every payload belonging to `owner`. The uninstall flow
    /// runs this while the tunnel extension still answers — once the
    /// extensions are deactivated there is no XPC peer left to ask,
    /// which is exactly how payloads used to outlive the app. `false`
    /// means the vault must not be treated as clean: the enumeration
    /// failed, or at least one item refused to go.
    static func purge(owner: uid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        _ = systemKeychain()

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

    // MARK: - Private

    /// Points the process's keychain search list at the system domain
    /// and hands back its default keychain. Resolved on every call —
    /// `securityd` connections do not survive across the extension's
    /// idle/relaunch cycles, and the call is cheap.
    private static func systemKeychain() -> SecKeychain? {
        let domainStatus = SecKeychainSetPreferenceDomain(.system)
        guard domainStatus == errSecSuccess else {
            report("setPreferenceDomain", id: "-", status: domainStatus)
            return nil
        }

        var keychain: SecKeychain?
        let status = SecKeychainCopyDomainDefault(.system, &keychain)
        guard status == errSecSuccess else {
            report("copyDomainDefault", id: "-", status: status)
            return nil
        }
        return keychain
    }

    /// The uid stamped on an item, or `nil` when no such item exists.
    /// Items written before ownership was recorded read as `nil` and
    /// are therefore inaccessible — deliberately, since guessing whose
    /// they are is worse than ignoring them. Callers hold `lock`.
    private static func ownerOf(id: String) -> uid_t? {
        var request = query(id: id)
        request[kSecReturnAttributes as String] = true

        var out: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &out) == errSecSuccess,
              let attributes = out as? [String: Any],
              let raw = attributes[kSecAttrDescription as String] as? String,
              let owner = uid_t(raw) else {
            return nil
        }
        return owner
    }

    /// Accounts (config ids) of every item stamped with `owner`, or
    /// `nil` when the enumeration itself failed. An empty vault is
    /// `[]` — `errSecItemNotFound` is a quiet normal here, not an
    /// error. Callers hold `lock`.
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
        return mine.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Single-item data read. Callers hold `lock`.
    private static func payload(for id: String) -> Data? {
        var request = query(id: id)
        request[kSecReturnData as String] = true

        var out: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &out)
        report("fetch", id: id, status: status)
        return out as? Data
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
