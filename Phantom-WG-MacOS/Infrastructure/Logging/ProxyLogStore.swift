import Foundation
import Observation

/// Polls a proxy daemon's log ring buffer over XPC on a 1-second
/// cadence and exposes the lines as `LogEntry` rows. One instance per
/// proxy — the daemon client fixes which extension is polled, `tag`
/// labels the rows (SPL / DNS).
@Observable
@MainActor
final class ProxyLogStore: LogEntryProvider {

    var entries: [LogEntry] = []

    @ObservationIgnored private weak var daemonClient: ProxyConfigDaemonClient?
    @ObservationIgnored private let tag: String
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    init(daemonClient: ProxyConfigDaemonClient, tag: String) {
        self.daemonClient = daemonClient
        self.tag = tag
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                await self?.fetchLogs()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Flushes the daemon's ring buffer and drops local entries.
    func clear() async {
        await daemonClient?.clearLogs()
        entries.removeAll()
    }

    // MARK: - Private

    private func fetchLogs() async {
        guard let daemonClient,
              let dump = await daemonClient.fetchLogs(),
              !dump.isEmpty else {
            if !entries.isEmpty { entries.removeAll() }
            return
        }

        entries = dump
            .split(separator: "\n", omittingEmptySubsequences: true)
            .enumerated()
            .map { index, line in
                LogEntry(
                    id: index,
                    tag: tag,
                    text: String(line)
                )
            }
    }
}
