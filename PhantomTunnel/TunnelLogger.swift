import Foundation

/// In-memory ring buffer logger for the tunnel extension.
/// Logs are disposable: visible during the session, gone on exit(0).
/// App retrieves logs via handleAppMessage.
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
        buffer.append(entry)
        if buffer.count > maxEntries {
            buffer.removeFirst(buffer.count - maxEntries)
        }
        lock.unlock()
    }

    /// Returns all buffered entries as JSON Data (for handleAppMessage).
    static func allEntriesAsData() -> Data? {
        lock.lock()
        let snapshot = buffer
        lock.unlock()
        return try? JSONEncoder().encode(snapshot)
    }
}
