import Foundation

/// In-memory paged logger for the tunnel extension. A full buffer is
/// cleared and the next line starts a new page, so the lines the app
/// reads never shift under it.
/// Logs are session-scoped: the buffer is flushed at `startTunnel`
/// entry so each tunnel session begins clean, even if iOS reuses the
/// extension process across start/stop cycles. The main app reads
/// entries via opcode 1 and can flush them on demand via opcode 2.
enum TunnelLogger {

    enum Tag: String {
        case tunnel = "TUN"
        case wstunnel = "WS"
        case wireGuard = "WG"
    }

    struct Entry: Codable {
        let timestamp: String
        let tag: String
        let message: String
    }

    private static let maxEntries = 2000
    private static var buffer: [Entry] = []
    private static let lock = NSLock()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ tag: Tag, _ message: String) {
        let entry = Entry(
            timestamp: formatter.string(from: Date()),
            tag: tag.rawValue,
            message: message
        )
        lock.lock()
        if buffer.count >= maxEntries {
            buffer.removeAll(keepingCapacity: true)
        }
        buffer.append(entry)
        lock.unlock()
    }

    /// Line count for opcode 4.
    static func entryCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    /// Snapshot of the current buffer serialized for `handleAppMessage`.
    static func allEntriesAsData() -> Data? {
        lock.lock()
        let snapshot = buffer
        lock.unlock()
        return try? JSONEncoder().encode(snapshot)
    }

    /// Wipes the buffer without tearing down the tunnel — a manual
    /// flush on top of the clear at `maxEntries`.
    static func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
