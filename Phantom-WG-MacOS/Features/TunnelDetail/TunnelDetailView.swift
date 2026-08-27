import SwiftUI

struct TunnelDetailView: View {
    var tunnel: TunnelContainer
    @State private var logStore: LogStore
    @Environment(TunnelsManager.self) var tunnelsManager
    @Environment(TunnelVaultClient.self) var vault
    @Environment(LocalizationManager.self) var loc
    @Environment(\.dismiss) var dismiss

    @State var config: TunnelConfig?
    @State var configLoaded = false
    @State var readAttempt = 0

    enum ConfigLoadFailure { case missing, undecodable, unreachable }
    @State var loadFailure: ConfigLoadFailure?

    static let vaultReadAttempts = 3

    @State var showingEdit = false
    @State var showingDeleteConfirmation = false
    @State var deleting = false
    @State var resetting = false
    @State var errorMessage: String?
    @State var showingError = false

    @State var lastHandshake: String = "—"
    @State var rxBytes: String = "—"
    @State var txBytes: String = "—"
    @State var statsPollingTask: Task<Void, Never>?
    @State private var configLoadTask: Task<Void, Never>?

    init(tunnel: TunnelContainer) {
        self.tunnel = tunnel
        _logStore = State(wrappedValue: LogStore(tunnel: tunnel))
    }

    var body: some View {
        Form {
            StatusSection(tunnel: tunnel, isGhost: tunnel.isGhost)

            StatsSection(handshake: lastHandshake, rxBytes: rxBytes, txBytes: txBytes)

            configSections

            LogNavigationSection(logStore: logStore)

            ActionsSection(
                tunnel: tunnel,
                canCopy: config != nil,
                copyAction: copyConf,
                editAction: { showingEdit = true },
                resetAction: resetConnection,
                resetting: resetting,
                deleting: deleting,
                showingDeleteConfirmation: $showingDeleteConfirmation
            )
        }
        .formStyle(.grouped)
        .navigationTitle(tunnel.name.isEmpty ? loc.t("detail_tunnel") : tunnel.name)
        .navigationDestination(isPresented: $showingEdit) {
            TunnelEditView(tunnel: tunnel)
        }
        .task { reloadConfig() }
        .onChange(of: showingEdit) { _, isEditing in
            if !isEditing {
                reloadConfig()
            }
        }
        .onAppear {
            logStore.startPolling()
            if Self.statsSessionImplied(tunnel.status) {
                startStatsPolling()
            } else {
                // The session may have ended while this screen was off-screen
                // (no onChange to catch it): repaint the placeholders so a
                // dead session's last rx/tx numbers do not come back.
                resetStats()
            }
        }
        .onDisappear {
            logStore.stopPolling()
            stopStatsPolling()
            configLoadTask?.cancel()
            configLoadTask = nil
        }
        .confirmationDialog(loc.t("detail_delete_confirm_title"),
                            isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button(loc.t("delete"), role: .destructive) { deleteTunnel() }
                .accessibilityIdentifier(AXID.TunnelDetail.Actions.deleteConfirm)
            Button(loc.t("cancel"), role: .cancel) {}
                .accessibilityIdentifier(AXID.TunnelDetail.Actions.deleteCancel)
        } message: {
            Text(loc.t("detail_delete_confirm_message"))
        }
        .alert(loc.t("error"), isPresented: $showingError) {
            Button(loc.t("ok")) {}
                .accessibilityIdentifier(AXID.TunnelDetail.errorAlertOK)
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: tunnel.status) { _, newStatus in
            switch newStatus {
            case .active, .reasserting:
                // Reasserting is a session-implying paint (statsSessionImplied):
                // the stats row keeps polling through the re-handshake window.
                startStatsPolling()
            case .inactive, .unknown:
                stopStatsPolling()
                resetStats()
            case .activating, .deactivating, .waiting:
                break
            }
        }
    }

    // MARK: - Configuration

    @ViewBuilder
    private var configSections: some View {
        if let config {
            NameSection(name: config.name)

            if let wstunnel = config.wstunnel {
                WstunnelSection(config: wstunnel)
            }

            InterfaceSection(config: config.wireguard.interface)

            PeerSection(config: config.wireguard.peer)
        } else if configLoaded {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    switch loadFailure {
                    case .unreachable:
                        Label(loc.t("detail_config_unreachable"), systemImage: "bolt.horizontal.circle")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(AXID.TunnelDetail.configUnreachable)
                    case .missing:
                        Label(loc.t("detail_config_missing"), systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(AXID.TunnelDetail.configUnavailable)
                    case .undecodable, nil:
                        Label(loc.t("detail_config_unavailable"), systemImage: "lock.slash")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(AXID.TunnelDetail.configUnavailable)
                    }

                    Button(loc.t("detail_config_retry")) {
                        reloadConfig()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier(AXID.TunnelDetail.configRetry)
                }
                .padding(.vertical, 2)
            }
        } else {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(readAttempt > 1
                         ? loc.t("detail_config_retrying", readAttempt, Self.vaultReadAttempts)
                         : loc.t("detail_config_loading"))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Single owner for config loads: every trigger (first appearance, edit
    /// dismissal, Retry) lands here, and a new trigger cancels the load in
    /// flight so only the newest answer paints the screen.
    private func reloadConfig() {
        configLoadTask?.cancel()
        configLoadTask = Task { await loadConfig() }
    }

    private func loadConfig() async {
        configLoaded = false
        readAttempt = 0

        let result = await vault.read(
            id: tunnel.id,
            attempts: Self.vaultReadAttempts,
            onAttempt: { if !Task.isCancelled { readAttempt = $0 } }
        )

        // A newer trigger owns the screen now; this answer is stale.
        guard !Task.isCancelled else { return }

        switch result {
        case .config(let loaded):
            config = loaded
            loadFailure = nil
        case .missing:
            config = nil
            loadFailure = .missing
        case .undecodable:
            config = nil
            loadFailure = .undecodable
        case .unreachable:
            config = nil
            loadFailure = .unreachable
        }
        configLoaded = true
    }
}

// MARK: - Previews

#Preview("Active ghost — Light") {
    let manager = PreviewFixtures.tunnelsManager(providers: [
        PreviewFixtures.provider(
            config: PreviewFixtures.ghostConfig(),
            status: .connected,
            logLines: PreviewFixtures.logLines
        )
    ])
    return NavigationStack {
        TunnelDetailView(tunnel: manager.tunnels[0])
    }
    .previewEnvironment(tunnels: manager, scheme: .light)
    .frame(width: 560, height: 720)
}

#Preview("Active ghost — Dark") {
    let manager = PreviewFixtures.tunnelsManager(providers: [
        PreviewFixtures.provider(
            config: PreviewFixtures.ghostConfig(),
            status: .connected,
            logLines: PreviewFixtures.logLines
        )
    ])
    return NavigationStack {
        TunnelDetailView(tunnel: manager.tunnels[0])
    }
    .previewEnvironment(tunnels: manager, scheme: .dark)
    .frame(width: 560, height: 720)
}

#Preview("Inactive standalone") {
    let manager = PreviewFixtures.tunnelsManager(providers: [
        PreviewFixtures.provider(config: PreviewFixtures.wireguardConfig())
    ])
    return NavigationStack {
        TunnelDetailView(tunnel: manager.tunnels[0])
    }
    .previewEnvironment(tunnels: manager)
    .frame(width: 560, height: 720)
}

#Preview("Config unreachable — Light") {
    let manager = PreviewFixtures.tunnelsManager(providers: [
        PreviewFixtures.provider(config: PreviewFixtures.ghostConfig())
    ])
    (manager.vault as? PreviewVaultClient)?.readOverride = .unreachable
    return NavigationStack {
        TunnelDetailView(tunnel: manager.tunnels[0])
    }
    .previewEnvironment(tunnels: manager, scheme: .light)
    .frame(width: 560, height: 720)
}

#Preview("Config unreachable — Dark") {
    let manager = PreviewFixtures.tunnelsManager(providers: [
        PreviewFixtures.provider(config: PreviewFixtures.ghostConfig())
    ])
    (manager.vault as? PreviewVaultClient)?.readOverride = .unreachable
    return NavigationStack {
        TunnelDetailView(tunnel: manager.tunnels[0])
    }
    .previewEnvironment(tunnels: manager, scheme: .dark)
    .frame(width: 560, height: 720)
}

#Preview("Activation error") {
    let manager = PreviewFixtures.tunnelsManager(providers: [
        PreviewFixtures.provider(config: PreviewFixtures.ghostConfig())
    ])
    manager.tunnels[0].lastActivationError = PreviewFixtures.activationError
    return NavigationStack {
        TunnelDetailView(tunnel: manager.tunnels[0])
    }
    .previewEnvironment(tunnels: manager)
    .frame(width: 560, height: 720)
}
