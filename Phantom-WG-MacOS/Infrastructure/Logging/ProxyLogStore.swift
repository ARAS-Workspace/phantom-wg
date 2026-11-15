import Foundation
import Observation

@Observable
@MainActor
final class ProxyLogStore: LogEntryProvider {

    var entries: [LogEntry] = []

    @ObservationIgnored private weak var daemonClient: ProxyConfigDaemonClient?
    @ObservationIgnored private let tag: String
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var idCounter = 0

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
                guard let self else { break }
                await self.fetchLogs()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

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

        entries = LogIdentity.identified(
            previous: entries,
            next: dump
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { (tag: tag, text: String($0)) },
            counter: &idCounter
        )
    }
}
