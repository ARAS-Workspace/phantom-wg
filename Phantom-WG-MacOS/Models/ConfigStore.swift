import Foundation
import SQLite3

/// SQLite-backed tunnel configuration storage for IPC between main app and Network Extension.
/// Both processes access the same database in the App Group container.
/// Follows the same WAL + FULLMUTEX pattern as SharedLogger.
enum ConfigStore {

    // MARK: - Validation Errors

    enum ValidationError: Error, LocalizedError {
        case emptyName
        case emptyWstunnelUrl
        case emptyPrivateKey
        case emptyPublicKey
        case emptyAddress
        case emptyEndpoint
        case invalidJson(detail: String)

        var errorDescription: String? {
            switch self {
            case .emptyName:          return "Configuration name is required."
            case .emptyWstunnelUrl:   return "Wstunnel server URL is required."
            case .emptyPrivateKey:    return "Interface private key is required."
            case .emptyPublicKey:     return "Peer public key is required."
            case .emptyAddress:       return "Interface address is required."
            case .emptyEndpoint:      return "Peer endpoint is required."
            case .invalidJson(let detail): return "Invalid configuration format: \(detail)"
            }
        }
    }

    // MARK: - SQLite Connection (per-process, lazy init)

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static var _db: OpaquePointer?
    private static var db: OpaquePointer? {
        if let existing = _db { return existing }

        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupID)?
            .appendingPathComponent("configs.sqlite") else { return nil }

        var connection: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK else { return nil }

        sqlite3_busy_timeout(connection, 3000)
        sqlite3_exec(connection, "PRAGMA journal_mode=WAL", nil, nil, nil)

        sqlite3_exec(connection, """
            CREATE TABLE IF NOT EXISTS tunnel_configs (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                json_data TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            )
            """, nil, nil, nil)

        _db = connection
        return connection
    }

    // MARK: - Validation

    static func validate(_ config: TunnelConfig) -> ValidationError? {
        if config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyName
        }
        if config.wstunnel.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyWstunnelUrl
        }
        if config.interface.privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyPrivateKey
        }
        if config.interface.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyAddress
        }
        if config.peer.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyPublicKey
        }
        if config.peer.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyEndpoint
        }
        return nil
    }

    /// Decodes JSON string to TunnelConfig with validation.
    static func decodeAndValidate(json: String) throws -> TunnelConfig {
        guard let data = json.data(using: .utf8) else {
            throw ValidationError.invalidJson(detail: "Input is not valid UTF-8 text.")
        }

        let config: TunnelConfig
        do {
            config = try JSONDecoder().decode(TunnelConfig.self, from: data)
        } catch {
            throw ValidationError.invalidJson(detail: error.localizedDescription)
        }

        if let validationError = validate(config) {
            throw validationError
        }

        return config
    }

    // MARK: - CRUD

    /// Save (insert or replace) a tunnel config.
    @discardableResult
    static func save(_ config: TunnelConfig) -> Bool {
        guard let db = db else { return false }
        guard let jsonData = try? JSONEncoder().encode(config),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return false }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO tunnel_configs (id, name, json_data, created_at, updated_at)
            VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                json_data = excluded.json_data,
                updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, config.id.uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, config.name, -1, transient)
        sqlite3_bind_text(stmt, 3, jsonString, -1, transient)

        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Load a single config by UUID.
    static func load(id: UUID) -> TunnelConfig? {
        guard let db = db else { return nil }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "SELECT json_data FROM tunnel_configs WHERE id = ?",
            -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, transient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let jsonString = String(cString: sqlite3_column_text(stmt, 0))
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TunnelConfig.self, from: data)
    }

    /// Load a single config by UUID string (convenience for configId from providerConfiguration).
    static func load(idString: String) -> TunnelConfig? {
        guard let uuid = UUID(uuidString: idString) else { return nil }
        return load(id: uuid)
    }

    /// Load all configs ordered by creation time.
    static func loadAll() -> [TunnelConfig] {
        guard let db = db else { return [] }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "SELECT json_data FROM tunnel_configs ORDER BY created_at ASC",
            -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var configs: [TunnelConfig] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let jsonString = String(cString: sqlite3_column_text(stmt, 0))
            if let data = jsonString.data(using: .utf8),
               let config = try? JSONDecoder().decode(TunnelConfig.self, from: data) {
                configs.append(config)
            }
        }
        return configs
    }

    /// Delete a config by UUID.
    @discardableResult
    static func delete(id: UUID) -> Bool {
        guard let db = db else { return false }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "DELETE FROM tunnel_configs WHERE id = ?",
            -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, transient)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Delete a config by UUID string.
    @discardableResult
    static func delete(idString: String) -> Bool {
        guard let uuid = UUID(uuidString: idString) else { return false }
        return delete(id: uuid)
    }
}
