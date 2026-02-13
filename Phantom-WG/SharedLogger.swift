import Foundation
import SQLite3

/// SQLite-backed shared logger for IPC between main app and Network Extension.
/// Both processes access the same database in the App Group container.
/// WAL mode enables concurrent read (app) + write (extension).
/// Auto-prunes when entry count exceeds threshold.
enum SharedLogger {

    enum Tag: String {
        case tunnel = "TUN"
        case wstunnel = "WS"
        case wireGuard = "WG"
    }

    struct Entry {
        let id: Int64
        let tunnelId: String?
        let timestamp: String
        let tag: String
        let message: String
    }

    /// Set by Network Extension at tunnel start. All subsequent log() calls
    /// automatically bind this value as tunnel_id.
    static var currentTunnelId: String?

    private static let maxEntries: Int32 = 5000
    private static let pruneCheckInterval = 100

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // SQLITE_TRANSIENT tells SQLite to copy the string immediately
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static var insertCounter = 0

    // Each process gets its own connection (static vars are per-process)
    private static var _db: OpaquePointer?
    private static var db: OpaquePointer? {
        if let existing = _db { return existing }

        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupID)?
            .appendingPathComponent("logs.sqlite") else { return nil }

        var connection: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK else { return nil }

        // WAL mode for concurrent read/write across processes
        sqlite3_busy_timeout(connection, 3000)
        sqlite3_exec(connection, "PRAGMA journal_mode=WAL", nil, nil, nil)

        sqlite3_exec(connection, """
            CREATE TABLE IF NOT EXISTS logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                tunnel_id TEXT,
                timestamp TEXT NOT NULL,
                tag TEXT NOT NULL,
                message TEXT NOT NULL
            )
            """, nil, nil, nil)

        // Migration: add tunnel_id to existing databases (no-op if column exists)
        sqlite3_exec(connection, "ALTER TABLE logs ADD COLUMN tunnel_id TEXT", nil, nil, nil)

        // Index for per-tunnel queries
        sqlite3_exec(connection, "CREATE INDEX IF NOT EXISTS idx_logs_tunnel_id ON logs(tunnel_id)", nil, nil, nil)

        _db = connection
        return connection
    }

    // MARK: - Write (called from Network Extension)

    static func log(_ tag: Tag, _ message: String) {
        guard let db = db else { return }
        let ts = formatter.string(from: Date())

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "INSERT INTO logs (tunnel_id, timestamp, tag, message) VALUES (?, ?, ?, ?)",
            -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        if let tid = currentTunnelId {
            sqlite3_bind_text(stmt, 1, tid, -1, transient)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_text(stmt, 2, ts, -1, transient)
        sqlite3_bind_text(stmt, 3, tag.rawValue, -1, transient)
        sqlite3_bind_text(stmt, 4, message, -1, transient)
        sqlite3_step(stmt)

        // Auto-prune periodically
        insertCounter += 1
        if insertCounter >= pruneCheckInterval {
            insertCounter = 0
            pruneIfNeeded(db)
        }
    }

    // MARK: - Read (called from main app)

    /// Returns entries with id > afterId, optionally filtered by tunnel.
    static func entriesSince(id afterId: Int64, tunnelId: String? = nil, limit: Int = 500) -> [Entry] {
        guard let db = db else { return [] }

        var stmt: OpaquePointer?
        let sql: String
        if tunnelId != nil {
            sql = "SELECT id, tunnel_id, timestamp, tag, message FROM logs WHERE id > ? AND tunnel_id = ? ORDER BY id ASC LIMIT ?"
        } else {
            sql = "SELECT id, tunnel_id, timestamp, tag, message FROM logs WHERE id > ? ORDER BY id ASC LIMIT ?"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, afterId)
        if let tid = tunnelId {
            sqlite3_bind_text(stmt, 2, tid, -1, transient)
            sqlite3_bind_int(stmt, 3, Int32(limit))
        } else {
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }

        var entries: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tid: String? = sqlite3_column_type(stmt, 1) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 1)) : nil
            entries.append(Entry(
                id: sqlite3_column_int64(stmt, 0),
                tunnelId: tid,
                timestamp: String(cString: sqlite3_column_text(stmt, 2)),
                tag: String(cString: sqlite3_column_text(stmt, 3)),
                message: String(cString: sqlite3_column_text(stmt, 4))
            ))
        }
        return entries
    }

    /// Returns the latest entry ID, optionally filtered by tunnel.
    static func latestId(tunnelId: String? = nil) -> Int64 {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        let sql: String
        if tunnelId != nil {
            sql = "SELECT COALESCE(MAX(id), 0) FROM logs WHERE tunnel_id = ?"
        } else {
            sql = "SELECT COALESCE(MAX(id), 0) FROM logs"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if let tid = tunnelId {
            sqlite3_bind_text(stmt, 1, tid, -1, transient)
        }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    /// Entry count, optionally filtered by tunnel.
    static func entryCount(tunnelId: String? = nil) -> Int64 {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        let sql: String
        if tunnelId != nil {
            sql = "SELECT COUNT(*) FROM logs WHERE tunnel_id = ?"
        } else {
            sql = "SELECT COUNT(*) FROM logs"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if let tid = tunnelId {
            sqlite3_bind_text(stmt, 1, tid, -1, transient)
        }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    /// Clear logs, optionally for a specific tunnel only.
    static func clear(tunnelId: String? = nil) {
        guard let db = db else { return }
        if let tid = tunnelId {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM logs WHERE tunnel_id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, tid, -1, transient)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        } else {
            sqlite3_exec(db, "DELETE FROM logs", nil, nil, nil)
            sqlite3_exec(db, "VACUUM", nil, nil, nil)
        }
    }

    // MARK: - Auto-prune

    private static func pruneIfNeeded(_ db: OpaquePointer) {
        guard let tid = currentTunnelId else {
            // Global prune (no tunnel context)
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM logs", -1, &stmt, nil) == SQLITE_OK else { return }
            let count = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
            sqlite3_finalize(stmt)

            if count > maxEntries {
                let excess = count - maxEntries
                sqlite3_exec(db, "DELETE FROM logs WHERE id IN (SELECT id FROM logs ORDER BY id ASC LIMIT \(excess))", nil, nil, nil)
            }
            return
        }

        // Per-tunnel prune
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM logs WHERE tunnel_id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, tid, -1, transient)
        let count = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
        sqlite3_finalize(stmt)

        if count > maxEntries {
            let excess = count - maxEntries
            var delStmt: OpaquePointer?
            let sql = "DELETE FROM logs WHERE id IN (SELECT id FROM logs WHERE tunnel_id = ? ORDER BY id ASC LIMIT \(excess))"
            guard sqlite3_prepare_v2(db, sql, -1, &delStmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(delStmt, 1, tid, -1, transient)
            sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }
    }
}
