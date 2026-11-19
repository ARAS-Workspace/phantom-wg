import SwiftUI
import UniformTypeIdentifiers

// MARK: - Actions & Stats Polling

extension TunnelDetailView {

    // MARK: - Copy

    /// Puts the `.conf` text, private key included, on the pasteboard
    /// once the owner grants it. The item is local-only, so Universal
    /// Clipboard does not carry it to the user's other devices. Returns
    /// whether anything was copied, for the button's "Copied!" feedback.
    func copyConf() async -> Bool {
        guard let contents = tunnel.tunnelConfig?.asConfString() else { return false }
        let granted = await PrivateDataGuard.grants(reason: loc.t("copy_private_data_reason")) { message in
            errorMessage = message
            showingError = true
        }
        guard granted else { return false }

        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: contents]],
            options: [.localOnly: true]
        )
        return true
    }

    // MARK: - Export

    /// Hands the `.conf` file, private key included, to the export
    /// picker once the owner grants it (`TunnelExportPicker`).
    func exportConf() {
        Task {
            let file = await TunnelConfFile.document(of: tunnel, reason: loc.t("export_private_data_reason")) { message in
                errorMessage = message
                showingError = true
            }
            guard let file, let presenter = TunnelExportPicker.topViewController() else { return }
            do {
                try TunnelExportPicker().present(file, over: presenter)
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    // MARK: - Edit

    /// The editor shows the raw `.conf`, private key included, so it
    /// opens only after the owner grants it — and only if the tunnel is
    /// still inactive once the question is answered.
    func openEdit() {
        Task {
            let granted = await PrivateDataGuard.grants(reason: loc.t("edit_private_data_reason")) { message in
                errorMessage = message
                showingError = true
            }
            guard granted, tunnel.status == .inactive else { return }
            showingEdit = true
        }
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

    /// Runs after the confirmation dialog. `deleting` holds the button
    /// down from the first press until the removal ends, across the
    /// owner question too; a decline or a failed removal lets it go.
    func deleteTunnel() {
        guard !deleting else { return }
        deleting = true
        Task {
            let granted = await PrivateDataGuard.grants(reason: loc.t("delete_private_data_reason")) { message in
                errorMessage = message
                showingError = true
            }
            guard granted else {
                deleting = false
                return
            }

            if tunnel.status != .inactive {
                tunnelsManager.startDeactivation(of: tunnel)
            }
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
                guard let stats = TunnelRuntimeStats.decoded(from: response) else { return }
                Task { @MainActor in
                    applyRuntimeStats(stats)
                }
            }
        } catch {
            // Session might not be ready yet
        }
    }

    func applyRuntimeStats(_ stats: TunnelRuntimeStats) {
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
