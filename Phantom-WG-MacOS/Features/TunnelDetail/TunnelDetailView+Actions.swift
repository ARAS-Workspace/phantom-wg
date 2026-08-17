import SwiftUI

// MARK: - Actions & Stats Polling

extension TunnelDetailView {

    /// Serializes the vault copy to the canonical `.conf` text — the
    /// same output `TunnelEditView` starts from, so what the user
    /// copies is exactly what they would edit. The button is disabled
    /// until the fetch lands, so `config` is non-nil here.
    func copyConf() {
        guard let contents = config?.asConfString() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contents, forType: .string)
    }

    /// Ask the extension to restart its tunnel layer in place.
    /// No user confirmation: reset is soft — worst case the user
    /// sees a brief disconnect and presses it again. utun / routes
    /// are preserved across the cycle (no physical-interface leak).
    /// One reset per sheet while one is in flight — the same shape
    /// `deleteTunnel` uses. The extension serializes overlapping
    /// resets now, so a second press can no longer make the adapter
    /// refuse itself; what this closes is the invitation, since the
    /// button stays enabled through `reasserting`, which is exactly
    /// the state a reset puts the session into.
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
        // One removal per sheet — see `deleting`. The manager's own
        // answer to a second one is silence, and silence here would
        // dismiss the screen the first removal still needs to report
        // to.
        guard !deleting else { return }
        deleting = true
        if tunnel.status != .inactive {
            tunnelsManager.startDeactivation(of: tunnel)
        }
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

        // Three states, three sentences. `pollStats` only runs while the
        // session is `.active`, so everything below is said about a
        // tunnel the app is showing as up — which is what makes the
        // first two worth telling apart at all.
        //
        // The dash used to cover the first two together, and it is the
        // same dash `resetStats` prints for "no data yet". So a tunnel
        // that came up and never completed a handshake — the
        // green-but-dead shape this project measures in its own suite —
        // read to the user exactly like one whose stats had not arrived.
        // The app could tell them apart and did not say so.
        if stats.lastHandshakeTimestamp == 0 {
            lastHandshake = loc.t("detail_handshake_never")
        } else {
            let date = Date(timeIntervalSince1970: TimeInterval(stats.lastHandshakeTimestamp))
            let elapsed = Date().timeIntervalSince(date)
            // 180s is REJECT_AFTER_TIME: past it the keypair behind the
            // displayed timestamp has expired, so the sentence "nothing
            // has replied since" is true whatever the cause. The
            // threshold is named rather than tuned, and the copy says
            // only that, never that the tunnel is broken.
            //
            // The stronger reading — that a peer this old has stopped
            // answering — holds only while something is SENDING, since
            // WireGuard rehandshakes on demand rather than on a clock.
            // Persistent keepalive is what guarantees it, and this app
            // supports the configuration that voids the guarantee:
            // `ConfParser` defaults keepalive to 25 only when the key
            // is ABSENT, validation admits 0, and the extension's
            // builder writes no keepalive at all for 0. So an idle
            // session on a keepalive-0 config ages past this line
            // legitimately. The copy survives that case; the diagnosis
            // would not, which is why it is not in the copy.
            lastHandshake = elapsed > 180
                ? loc.t("detail_handshake_stale", StatsFormatter.formatTimeAgo(elapsed, loc: loc))
                : StatsFormatter.formatTimeAgo(elapsed, loc: loc)
        }
    }
}
