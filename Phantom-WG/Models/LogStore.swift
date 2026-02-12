import Foundation

@MainActor
final class LogStore: ObservableObject {
    @Published var entries: [LogEntry] = []

    let tunnelId: String?
    private var lastSeenId: Int64 = 0
    private var pollTimer: Timer?

    init(tunnelId: String? = nil) {
        self.tunnelId = tunnelId
    }

    struct LogEntry: Identifiable {
        let id: Int64
        let tag: String
        let timestamp: String
        let text: String  // formatted: "[HH:mm:ss.SSS][TAG] message"
    }

    /// Load all existing logs from DB and start polling for new ones.
    func startPolling() {
        guard pollTimer == nil else { return }
        loadAll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollOnce()
            }
        }
    }

    /// Stop polling (view disappeared).
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Explicit clear: wipe logs for this tunnel and reset view.
    func clear() {
        entries.removeAll()
        lastSeenId = 0
        SharedLogger.clear(tunnelId: tunnelId)
    }

    // MARK: - Private

    private func loadAll() {
        entries.removeAll()
        lastSeenId = 0

        let all = SharedLogger.entriesSince(id: 0, tunnelId: tunnelId, limit: 5000)
        for entry in all {
            entries.append(LogEntry(
                id: entry.id,
                tag: entry.tag,
                timestamp: entry.timestamp,
                text: "[\(entry.timestamp)][\(entry.tag)] \(entry.message)"
            ))
        }
        if let last = all.last {
            lastSeenId = last.id
        }
    }

    private func pollOnce() {
        let newEntries = SharedLogger.entriesSince(id: lastSeenId, tunnelId: tunnelId)
        guard !newEntries.isEmpty else { return }

        lastSeenId = newEntries.last!.id

        for entry in newEntries {
            entries.append(LogEntry(
                id: entry.id,
                tag: entry.tag,
                timestamp: entry.timestamp,
                text: "[\(entry.timestamp)][\(entry.tag)] \(entry.message)"
            ))
        }

        // Mirror auto-prune: if in-memory entries exceed DB max, trim oldest
        if entries.count > 5000 {
            entries.removeFirst(entries.count - 5000)
        }
    }
}
