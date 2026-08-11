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
/// No keychain is ever named explicitly. A system extension runs in
/// the system context, and there — per Apple's TN3137 — "the search
/// list includes just the System keychain, which is also the default
/// keychain": every `SecItem` call lands on the right store by
/// contract. Pinning the domain by hand would take the `SecKeychain*`
/// functions, all deprecated since macOS 10.10 — this file
/// deliberately depends on none of them.
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
/// account already identifies the item, and on the file-based keychain
/// a persistent reference goes stale the moment an item's attributes
/// are updated — an attribute query cannot dangle. Only the extension
/// calls this type; the app reaches it through `TunnelVaultDaemon`
/// over XPC.
enum SystemKeychainVault {

    static let service = "com.remrearas.Phantom-WG-MacOS.tunnelvault"

    private static let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomTunnel",
        category: "vault"
    )

    /// Serializes keychain access — RPCs arrive on XPC queues while
    /// `startTunnel` reads in-process on its own thread.
    private static let lock = NSLock()

    /// Outcome of a single payload read. Absence and failure are kept
    /// apart on purpose: the reconcile pass drops system entries on
    /// the strength of "the vault holds nothing here", and a keychain
    /// that could not answer must never sound like that.
    enum FetchResult {
        case payload(Data)
        case missing
        case failed
    }

    // MARK: - CRUD

    /// Writes (or replaces) the vault item for `id`, stamped with the
    /// owning uid. Upsert — `SecItemUpdate` first, `SecItemAdd` only
    /// when there is nothing to update: a failed update leaves the old
    /// item fully intact, so no moment exists in which the only copy
    /// of a tunnel's keys lives outside the keychain. (The former
    /// delete-then-add carried that moment, and its rollback could
    /// itself fail — a double failure lost the secret outright.)
    /// Attribute lookup keeps this safe from the file-based keychain's
    /// quirk of invalidating persistent references on attribute
    /// updates — nothing here ever holds one.
    @discardableResult
    static func store(_ payload: Data, id: String, owner: uid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Replacing someone else's item is not a write, it is a theft
        // of their slot. Ids are random so this should never happen;
        // refusing costs nothing and closes the case where it does.
        // An owner that cannot be read is refused the same way —
        // never overwrite a slot that could not be identified.
        switch ownerOf(id: id) {
        case .stamped(let existing) where existing != owner:
            report("store(denied — owned by \(existing))", id: id, status: errSecAuthFailed)
            return false
        case .failed:
            return false
        default:
            break
        }

        // The update carries the same three fields the add writes, so
        // an item that predates ownership stamping leaves this call
        // stamped either way.
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
            // Scoping reads as absence — another account's item is not
            // this caller's to know about.
            report("fetch(denied — not the owner)", id: id, status: errSecItemNotFound)
            return .missing
        case .failed:
            return .failed
        default:
            return payload(for: id)
        }
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

        guard case .payload(let data) = payload(for: id) else { return nil }
        return data
    }

    @discardableResult
    static func delete(id: String, owner: uid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        switch ownerOf(id: id) {
        case .none:
            // Already gone is success for the caller's purposes.
            return true
        case .stamped(let existing) where existing != owner:
            report("delete(denied — owned by \(existing))", id: id, status: errSecAuthFailed)
            return false
        case .failed:
            // Could not tell whose it is — do not claim it is gone.
            return false
        default:
            break
        }

        let status = SecItemDelete(query(id: id) as CFDictionary)
        report("delete", id: id, status: status)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Every payload belonging to `owner`, or `nil` when the
    /// enumeration itself failed. The reconcile pass compares this
    /// answer against the system store and deletes entries on
    /// emptiness, so a failed enumeration must never read as an empty
    /// vault. An item that enumerates but fails to read is dropped
    /// from the answer; the app's per-candidate confirm keeps that
    /// from costing a system entry.
    static func fetchAll(owner: uid_t) -> [Data]? {
        lock.lock()
        defer { lock.unlock() }

        // Two passes on purpose: the file-based keychain rejects a
        // bulk query that asks for item *data* (`kSecMatchLimitAll`
        // with `kSecReturnData` answers errSecParam), so enumerate the
        // accounts first and then read each payload with the
        // single-item query that is known to work.
        guard let accounts = accounts(of: owner) else { return nil }
        var payloads: [Data] = []
        for account in accounts {
            switch payload(for: account) {
            case .payload(let data):
                payloads.append(data)
            case .missing:
                // Raced a delete between enumerate and read — skipping
                // it is honest, the item is genuinely gone.
                continue
            case .failed:
                // A real read failure must never shrink the vault into a
                // shorter-but-valid list the reconcile pass would trust:
                // the whole enumeration is unusable.
                return nil
            }
        }
        return payloads
    }

    /// Deletes every payload belonging to `owner` — the vault's
    /// complete per-user erasure primitive. No shipping caller
    /// remains (the uninstall flow preserves user data by contract;
    /// the `purgeVault` XPC endpoint layered above in
    /// `TunnelVaultDaemon` stays for wire-stability), but the
    /// semantics hold for whoever invokes it: `false` means the vault
    /// must not be treated as clean — the enumeration failed, or at
    /// least one item refused to go.
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

    /// Door check for the session probe: proves the keychain domain
    /// opens and enumeration answers, and counts the caller's payloads
    /// without moving one. `nil` mirrors `fetchAll` — the door did not
    /// open.
    static func count(owner: uid_t) -> Int? {
        lock.lock()
        defer { lock.unlock() }

        return accounts(of: owner)?.count
    }

    // MARK: - Private

    /// Owner lookup, three-way for the same reason as `FetchResult`:
    /// "no such item" clears the way, "could not ask" must not.
    /// Items written before ownership was recorded read as `.none` and
    /// are therefore inaccessible — deliberately, since guessing whose
    /// they are is worse than ignoring them. Callers hold `lock`.
    private enum OwnerLookup {
        case stamped(uid_t)
        case none
        case failed
    }

    private static func ownerOf(id: String) -> OwnerLookup {
        var request = query(id: id)
        request[kSecReturnAttributes as String] = true

        var out: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &out)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return .none }
            report("ownerOf", id: id, status: status)
            return .failed
        }
        guard let attributes = out as? [String: Any],
              let raw = attributes[kSecAttrDescription as String] as? String,
              let owner = uid_t(raw) else {
            return .none
        }
        return .stamped(owner)
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

        // The merged search list can present the System keychain more
        // than once, and a bulk match then answers the same physical
        // item once per list entry — field-measured as every item
        // enumerated exactly twice. One account, one answer.
        var seen = Set<String>()
        return mine.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { seen.insert($0).inserted }
    }

    /// Single-item data read. Callers hold `lock`.
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
