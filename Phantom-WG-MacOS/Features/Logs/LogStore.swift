import Foundation

struct LogEntry: Identifiable, Hashable {
    let id: Int
    let tag: String
    let text: String
}

@MainActor
protocol LogEntryProvider: AnyObject, Observable {
    var entries: [LogEntry] { get }
    func startPolling()
    func stopPolling()
    func clear() async
}

@Observable
@MainActor
final class LogStore: LogEntryProvider {
    var entries: [LogEntry] = []

    @ObservationIgnored private weak var tunnel: TunnelContainer?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    init(tunnel: TunnelContainer?) {
        self.tunnel = tunnel
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(0.5))
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

    func clear() async {
        if tunnel?.status == .active || tunnel?.status == .activating {
            _ = await sendMessage(Data([2]))
        }
        entries.removeAll()
    }

    // MARK: - Private

    private func fetchLogs() async {
        guard let tunnel, tunnel.status == .active || tunnel.status == .activating else {
            if !entries.isEmpty { entries.removeAll() }
            return
        }

        do {
            let data = await sendMessage(Data([1]))
            guard let data else { return }

            let decoded = try JSONDecoder().decode([RemoteEntry].self, from: data)

            entries = decoded.enumerated().map { index, entry in
                LogEntry(
                    id: index,
                    tag: entry.tag,
                    text: "[\(entry.timestamp)][\(entry.tag)] \(entry.message)"
                )
            }
        } catch {
        }
    }

    private func sendMessage(_ data: Data) async -> Data? {
        guard let tunnel else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let resume = SingleResume(continuation)
            do {
                try tunnel.tunnelProvider.sendProviderMessage(data) { response in
                    resume.finish(response)
                }
            } catch {
                resume.finish(nil)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(Self.replyBudget))
                resume.finish(nil)
            }
        }
    }

    private nonisolated static let replyBudget: TimeInterval = 5

    private struct RemoteEntry: Codable {
        let timestamp: String
        let tag: String
        let message: String
    }
}
