import Foundation
import Observation

/// Polls the SplitTunnel daemon's log ring buffer over XPC on a
/// 1-second cadence and exposes the lines as `LogEntry` rows.
@Observable
@MainActor
final class SplitTunnelLogStore: LogEntryProvider {

    var entries: [LogEntry] = []

    @ObservationIgnored private weak var daemonClient: SplitTunnelDaemonClient?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    init(daemonClient: SplitTunnelDaemonClient) {
        self.daemonClient = daemonClient
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

    /// Flushes the extension's ring buffer and drops local entries.
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
                    tag: "SPL",
                    timestamp: "",
                    text: String(line)
                )
            }
    }
}
