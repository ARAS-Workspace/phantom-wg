import SwiftUI

// MARK: - Actions & Stats Polling

extension TunnelDetailView {

    func copyConf() {
        guard let contents = config?.asConfString() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contents, forType: .string)
    }

    func resetConnection() {
        guard !resetting else { return }
        resetting = true
        Task {
            defer { resetting = false }
            do {
                try await tunnelsManager.resetConnection(of: tunnel)
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    func deleteTunnel() {
        guard !deleting else { return }
        deleting = true
        // Decision: a confirmed delete carries its own stop unconditionally.
        // No pre-filter here — startDeactivation's entry gate reads both
        // surfaces itself and returns silently in every sessionless
        // combination.
        tunnelsManager.startDeactivation(of: tunnel)
        Task {
            do {
                try await tunnelsManager.remove(tunnel: tunnel)
                dismiss()
            } catch {
                deleting = false
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    // MARK: - Stats Polling

    /// The paints under which the stats row assumes a session worth asking:
    /// the start triggers (onAppear, status onChange), the pollStats guard
    /// and the applyRuntimeStats precondition all read this one predicate.
    static func statsSessionImplied(_ status: TunnelStatus) -> Bool {
        status == .active || status == .reasserting
    }

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
        guard Self.statsSessionImplied(tunnel.status) else { return }

        do {
            try tunnel.tunnelProvider.sendProviderMessage(Data([0])) { response in
                guard let data = response, let config = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    applyRuntimeStats(config)
                }
            }
        } catch {
        }
    }

    func applyRuntimeStats(_ config: String) {
        // Paint only under a session-implying row; a reply that lands after
        // the drop must not overwrite the reset placeholders.
        guard Self.statsSessionImplied(tunnel.status) else { return }

        let stats = StatsFormatter.parse(config)
        rxBytes = StatsFormatter.formatBytes(stats.rxBytes)
        txBytes = StatsFormatter.formatBytes(stats.txBytes)

        if stats.lastHandshakeTimestamp == 0 {
            lastHandshake = loc.t("detail_handshake_never")
        } else {
            let date = Date(timeIntervalSince1970: TimeInterval(stats.lastHandshakeTimestamp))
            let elapsed = Date().timeIntervalSince(date)
            lastHandshake = elapsed > 180
                ? loc.t("detail_handshake_stale", StatsFormatter.formatTimeAgo(elapsed, loc: loc))
                : StatsFormatter.formatTimeAgo(elapsed, loc: loc)
        }
    }
}
