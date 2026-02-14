import Foundation
import NetworkExtension

/// Fetches logs from the tunnel extension via handleAppMessage.
/// Logs are disposable: visible during the session, gone when tunnel stops.
@MainActor
final class LogStore: ObservableObject {
    @Published var entries: [LogEntry] = []

    private weak var tunnel: TunnelContainer?
    private var pollingTask: Task<Void, Never>?

    struct LogEntry: Identifiable, Hashable {
        let id: Int
        let tag: String
        let timestamp: String
        let text: String
    }

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
