import Foundation

/// Shared row shape so the log panels can render the tunnel
/// extension's structured entries and the proxy daemons' plain-line
/// dumps without branching on concrete store type.
struct LogEntry: Identifiable, Hashable {
    let id: Int
    let tag: String
    let text: String
}

/// Read surface satisfied by `LogStore` and `ProxyLogStore`.
/// `LogView` takes any of these and never distinguishes between
/// the sources.
@MainActor
protocol LogEntryProvider: AnyObject, Observable {
    var entries: [LogEntry] { get }
    func startPolling()
    func stopPolling()
    /// Flushes the backing log source and the main-app's mirror
    /// array; polling keeps running, so new lines keep streaming.
    func clear() async
}

/// Fetches logs from the tunnel extension via handleAppMessage.
/// Logs are disposable: visible during the session, gone when tunnel stops.
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

    /// Opcode `2` — wipe the extension's ring buffer, then drop local
    /// entries. Polling keeps running; fresh emissions reappear as the
    /// tunnel continues to run.
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
            // Extension not reachable or decode failed - ignore silently
        }
    }

    /// Both opcodes this store sends go through here, and the wait is
    /// BOUNDED. It was not: an extension that took the message and
    /// never called back left this continuation suspended forever,
    /// and both callers paid for it in a way the user could see. The
    /// poll loop awaits this before it sleeps again, so a single mute
    /// call ended log streaming for the rest of the session while the
    /// panel kept showing the last lines it had — and `stopPolling`
    /// could not undo it, since cancelling a task does not resume a
    /// continuation nobody is going to resume. The Clear button
    /// awaited it directly.
    ///
    /// A timeout is reported as an absent reply rather than as an
    /// error, because that is what it is: both callers already treat
    /// "no data" as nothing to do, and a mute extension is not a
    /// failure of the log panel. Five seconds is the ceiling the
    /// vault client uses for the same round trip to the same
    /// extension.
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

    /// Wall-clock ceiling for one provider-message round trip.
    private nonisolated static let replyBudget: TimeInterval = 5

    private struct RemoteEntry: Codable {
        let timestamp: String
        let tag: String
        let message: String
    }
}
