import Foundation

/// Row shape rendered by `LogView`. Kept as a protocol surface so the
/// view never needs to know the concrete store — matches the macOS
/// counterpart even though iOS currently ships with a single store.
struct LogEntry: Identifiable, Hashable {
    let id: Int
    let tag: String
    let text: String
}

/// Read surface that `LogStore` satisfies. `LogView` takes one of
/// these and treats the source as opaque.
@MainActor
protocol LogEntryProvider: AnyObject, Observable {
    var entries: [LogEntry] { get }
    func startPolling()
    func stopPolling()
    /// Flushes the backing log source and the main-app's mirror
    /// array; polling keeps running, so new lines keep streaming.
    func clear() async
}

/// Fetches logs from the tunnel extension via `handleAppMessage`.
/// Logs are session-scoped: visible while the tunnel is running,
/// absent when inactive (the extension clears its buffer on
/// `startTunnel` entry so every session begins fresh).
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

    /// Each screen that shows the entries holds the poller while it is
    /// on screen; the poller runs while any hold is left.
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
                await self?.fetchLogs()
            }
        }
    }

    func stopPolling() {
        pollingHolds = max(0, pollingHolds - 1)
        guard pollingHolds == 0 else { return }
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Opcode `2` — wipe the extension's ring buffer, then drop local
    /// entries. Polling keeps running; fresh emissions reappear as the
    /// tunnel continues to run.
    func clear() async {
        if let tunnel, Self.sessionImplied(tunnel.status) {
            _ = await sendMessage(Data([2]))
        }
        entries.removeAll()
    }

    // MARK: - Private

    /// A reset keeps the session up while the layer is rebuilt, so
    /// `.reasserting` keeps the entries too.
    private static func sessionImplied(_ status: TunnelStatus) -> Bool {
        status == .active || status == .activating || status == .reasserting
    }

    private func fetchLogs() async {
        guard let tunnel else { return }

        guard Self.sessionImplied(tunnel.status) else {
            if !entries.isEmpty { entries.removeAll() }
            return
        }

        guard let data = await sendMessage(Data([1])) else { return }

        guard Self.sessionImplied(tunnel.status) else { return }

        do {
            let decoded = try JSONDecoder().decode([RemoteEntry].self, from: data)
            entries = identify(decoded)
        } catch {
            // Decode failed — ignore silently; the next poll brings a
            // fresh buffer. An unreachable extension never gets here:
            // `sendMessage` reads it as nothing new to show.
        }
    }

    /// App-side identity for snapshot rows: ids come from a flowing
    /// counter, and a row keeps its id while it still lines up with the
    /// previous snapshot — so `entries.last?.id` moves when the tail
    /// actually changed, which is what the log screen's scroll trigger
    /// reads.
    private func identify(_ decoded: [RemoteEntry]) -> [LogEntry] {
        LogIdentity.identified(
            previous: entries,
            next: decoded.map { (tag: $0.tag, text: "[\($0.timestamp)][\($0.tag)] \($0.message)") },
            counter: &idCounter
        )
    }

    /// An extension that has died answers nothing at all, and the poll
    /// loop above advances only when this returns — so without a bound
    /// on the wait the log panel freezes for good, and `stopPolling`
    /// cannot free it either: cancelling a task suspended on a
    /// continuation nobody will resume changes nothing.
    ///
    /// The bound ends the wait, not the message: the request is never
    /// withdrawn, and a reply that lands late finds the slot taken and
    /// is dropped rather than painting a stale buffer over a newer one.
    /// A missing answer reads the same as an empty one here, because
    /// for a log panel it is: there is nothing new to show.
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
