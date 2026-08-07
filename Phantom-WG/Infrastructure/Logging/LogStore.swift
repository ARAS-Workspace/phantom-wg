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
                    text: "[\(entry.timestamp)][\(entry.tag)] \(entry.message)"
                )
            }
        } catch {
            // Extension not reachable or decode failed — ignore silently.
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
