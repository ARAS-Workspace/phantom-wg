import Foundation

final class RingBufferLogger {

    static let shared = RingBufferLogger()

    private let capacity: Int
    private let lock = NSLock()
    private var buffer: [String]
    private let formatter: ISO8601DateFormatter

    init(capacity: Int = 500) {
        self.capacity = capacity
        self.buffer = []
        self.buffer.reserveCapacity(capacity)
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    // MARK: - Write

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        lock.lock()
        if buffer.count >= capacity {
            buffer.removeFirst(buffer.count - capacity + 1)
        }
        buffer.append(line)
        lock.unlock()
    }

    // MARK: - Drain

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return buffer.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

// MARK: - App-list Diff

extension RingBufferLogger {
    func logAppDiff(previous: [AppEntry], current: [AppEntry]) {
        let prevIDs = Set(previous.map(\.signingIdentifier))
        let nextIDs = Set(current.map(\.signingIdentifier))
        for app in current where !prevIDs.contains(app.signingIdentifier) {
            log("[config] + \(app.displayName) (\(app.signingIdentifier))")
        }
        for app in previous where !nextIDs.contains(app.signingIdentifier) {
            log("[config] - \(app.displayName) (\(app.signingIdentifier))")
        }
    }
}
