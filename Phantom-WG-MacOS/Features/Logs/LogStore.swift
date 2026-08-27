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
    @ObservationIgnored private var pollingHolds = 0
    @ObservationIgnored private var idCounter = 0

    init(tunnel: TunnelContainer?) {
        self.tunnel = tunnel
    }

    /// Every screen that shows log rows (the detail badge, the log screen)
    /// holds the poller while visible. Holds are a plain count — not a
    /// state machine — because on push/pop the incoming screen's start can
    /// land before the outgoing screen's stop, in either order.
    func startPolling() {
        pollingHolds += 1
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(0.5))
                } catch {
                    break
                }
                guard let self else { break }
                await self.fetchLogs()
            }
        }
    }

    func stopPolling() {
        pollingHolds = max(0, pollingHolds - 1)
        guard pollingHolds == 0 else { return }
        pollingTask?.cancel()
        pollingTask = nil
    }

    func clear() async {
        if let tunnel, Self.sessionImplied(tunnel.status) {
            _ = await sendMessage(Data([2]))
        }
        entries.removeAll()
    }

    // MARK: - Private

    /// Decision: the log window is a session ledger — rows are visible
    /// while a session-implying paint is up and are wiped when it is not.
    /// Tunnel connection logs carry no persistence promise: a deliberate
    /// departure from the official client's global buffer, because the
    /// extension's cross-session buffer is not an accessible whole. The
    /// stats row differs in exactly one way: it carries the session's
    /// last-known numbers until a terminal paint, while the log ledger
    /// closes with the session.
    private static func sessionImplied(_ status: TunnelStatus) -> Bool {
        status == .active || status == .activating || status == .reasserting
    }

    private func fetchLogs() async {
        // A detached store (nil tunnel: previews, torn-down container) has
        // no source to ask; it stays inert rather than wiping seeded rows.
        guard let tunnel else { return }

        guard Self.sessionImplied(tunnel.status) else {
            if !entries.isEmpty { entries.removeAll() }
            return
        }

        do {
            let data = await sendMessage(Data([1]))
            guard let data else { return }

            // The same predicate, re-read after the await (the stats row's
            // written principle): a reply that lands after the drop must not
            // repaint a wiped screen. A Clear racing this fetch may repaint
            // once; the next tick (<=0.5s) wipes it again — no generation
            // counter by design.
            guard Self.sessionImplied(tunnel.status) else { return }

            let decoded = try JSONDecoder().decode([RemoteEntry].self, from: data)
            entries = identify(decoded)
        } catch {
        }
    }

    /// App-side identity for snapshot rows: ids come from a flowing counter,
    /// and a row keeps its id while it still lines up with the previous
    /// snapshot — so `entries.last?.id` moves when the tail actually changed,
    /// which is what the log screen's scroll trigger reads.
    private func identify(_ decoded: [RemoteEntry]) -> [LogEntry] {
        var result: [LogEntry] = []
        result.reserveCapacity(decoded.count)
        var reusing = decoded.count >= entries.count
        for (index, remote) in decoded.enumerated() {
            let text = "[\(remote.timestamp)][\(remote.tag)] \(remote.message)"
            if reusing, index < entries.count, entries[index].text == text {
                result.append(entries[index])
            } else {
                reusing = false
                idCounter += 1
                result.append(LogEntry(id: idCounter, tag: remote.tag, text: text))
            }
        }
        return result
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
