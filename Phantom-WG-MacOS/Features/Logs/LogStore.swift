import Foundation

/// Shared row shape so the log panels can render the tunnel
/// extension's structured entries and the proxy daemons' plain-line
/// dumps without branching on concrete store type.
struct LogEntry: Identifiable, Hashable {
    let id: Int
    let tag: String
    let timestamp: String
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
    /// Flushes both the in-extension ring buffer (via opcode message)
    /// and the main-app's mirror array. Re-emits existing polling —
    /// new lines from the extension continue streaming normally.
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
            _ = try? await sendMessage(Data([2]))
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
            let data = try await sendMessage(Data([1]))
            guard let data else { return }

            let decoded = try JSONDecoder().decode([RemoteEntry].self, from: data)

            entries = decoded.enumerated().map { index, entry in
                LogEntry(
                    id: index,
                    tag: entry.tag,
                    timestamp: entry.timestamp,
                    text: "[\(entry.timestamp)][\(entry.tag)] \(entry.message)"
                )
            }
        } catch {
            // Extension not reachable or decode failed - ignore silently
        }
    }

    private func sendMessage(_ data: Data) async throws -> Data? {
        guard let tunnel else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try tunnel.tunnelProvider.sendProviderMessage(data) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private struct RemoteEntry: Codable {
        let timestamp: String
        let tag: String
        let message: String
    }
}
