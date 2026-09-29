import SwiftUI

// MARK: - Actions & Stats Polling

extension TunnelDetailView {

    // MARK: - Copy

    func copyConf() {
        guard let contents = tunnel.tunnelConfig?.asConfString() else { return }
        UIPasteboard.general.string = contents
    }

    // MARK: - Reset

    /// Ask the extension to restart its tunnel layer in place.
    /// No user confirmation: reset is soft — utun / routes are
    /// preserved across the cycle (no physical-interface leak), so the
    /// worst case is a brief disconnect. What it is not is silent: the
    /// call returns the layer's own verdict, and a rebuild that left
    /// the layer down is said here rather than left to look like the
    /// working one.
    func resetConnection() {
        Task {
            isResetting = true
            defer { isResetting = false }
            do {
                try await tunnelsManager.resetConnection(of: tunnel)
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    // MARK: - Delete

    func deleteTunnel() {
        if tunnel.status != .inactive {
            tunnelsManager.startDeactivation(of: tunnel)
        }
        Task {
            do {
                try await tunnelsManager.remove(tunnel: tunnel)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    // MARK: - Stats Polling

    func startStatsPolling() {
        stopStatsPolling()
        pollStats()
        statsPollingTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                pollStats()
            }
        }
    }

    func stopStatsPolling() {
        statsPollingTask?.cancel()
        statsPollingTask = nil
    }

    func resetStats() {
        lastHandshake = "—"
        rxBytes = "—"
        txBytes = "—"
    }

    func pollStats() {
        guard tunnel.status == .active else { return }

        do {
            try tunnel.tunnelProvider.sendProviderMessage(Data([0])) { response in
                guard let data = response, let config = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    applyRuntimeStats(config)
                }
            }
        } catch {
            // Session might not be ready yet
        }
    }

    func applyRuntimeStats(_ config: String) {
        let stats = StatsFormatter.parse(config)
        rxBytes = StatsFormatter.formatBytes(stats.rxBytes)
        txBytes = StatsFormatter.formatBytes(stats.txBytes)

        if stats.lastHandshakeTimestamp > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(stats.lastHandshakeTimestamp))
            let elapsed = Date().timeIntervalSince(date)
            lastHandshake = StatsFormatter.formatTimeAgo(elapsed, loc: loc)
        } else {
            lastHandshake = "—"
        }
    }
}
