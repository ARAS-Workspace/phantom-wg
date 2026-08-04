import SwiftUI

/// Tunnel detail — read-only presentation of the saved configuration
/// plus live status, stats, and logs. Status and stats come from the
/// identity the system's preferences hold, so they render instantly;
/// the configuration itself is fetched from the extension's vault,
/// which is the only place a tunnel's secrets exist. Editing happens
/// as raw text in `TunnelEditView` (Actions → Edit Config), enabled
/// only while the tunnel is inactive.
struct TunnelDetailView: View {
    var tunnel: TunnelContainer
    @State private var logStore: LogStore
    @Environment(TunnelsManager.self) var tunnelsManager
    @Environment(TunnelVaultClient.self) var vault
    @Environment(LocalizationManager.self) var loc
    @Environment(\.dismiss) var dismiss

    /// Vault payload, once it arrives. Reads are retried while the
    /// screen is open — the extension is spawned on demand and the
    /// first attempt after it has been idle can lose the race, which
    /// is not something to report as a broken configuration.
    @State var config: TunnelConfig?
    @State var configLoaded = false
    @State var readAttempt = 0

    /// How many times a read is tried before the screen calls the
    /// configuration unreadable.
    static let vaultReadAttempts = 3

    @State var showingEdit = false
    @State var showingDeleteConfirmation = false
    @State var errorMessage: String?
    @State var showingError = false

    // Stats
    @State var lastHandshake: String = "—"
    @State var rxBytes: String = "—"
    @State var txBytes: String = "—"
    @State var statsPollingTask: Task<Void, Never>?

    init(tunnel: TunnelContainer) {
        self.tunnel = tunnel
        _logStore = State(wrappedValue: LogStore(tunnel: tunnel))
    }

    var body: some View {
        // A form rather than a list: this screen only displays and
        // navigates, and the list container is the one that keeps
        // leaving a band of empty space above its first row after a
        // navigation push. Every form-based screen in the app has
        // been free of that.
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
                showingDeleteConfirmation: $showingDeleteConfirmation
            )
        }
        .formStyle(.grouped)
        .navigationTitle(tunnel.name.isEmpty ? loc.t("detail_tunnel") : tunnel.name)
        .navigationDestination(isPresented: $showingEdit) {
            TunnelEditView(tunnel: tunnel)
        }
        .task { await loadConfig() }
        .onChange(of: showingEdit) { _, isEditing in
            // Returning from the editor: re-read the vault so the
            // sections show what was just saved.
            if !isEditing {
                Task { await loadConfig() }
            }
        }
        .onAppear {
            logStore.startPolling()
            if tunnel.status == .active { startStatsPolling() }
        }
        .onDisappear {
            logStore.stopPolling()
            stopStatsPolling()
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
            if newStatus == .active {
                startStatsPolling()
            } else if newStatus == .inactive {
                stopStatsPolling()
                resetStats()
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
                    Label(loc.t("detail_config_unavailable"), systemImage: "lock.slash")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(AXID.TunnelDetail.configUnavailable)

                    Button(loc.t("detail_config_retry")) {
                        Task { await loadConfig() }
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

    /// Reads the vault, retrying a few times before giving up. The
    /// loop lives in the screen's task, so walking away cancels it.
    private func loadConfig() async {
        configLoaded = false
        readAttempt = 0

        let result = await vault.read(
            id: tunnel.id,
            attempts: Self.vaultReadAttempts,
            onAttempt: { readAttempt = $0 }
        )

        switch result {
        case .config(let loaded):
            config = loaded
        case .missing, .unreachable:
            config = nil
        }
        configLoaded = true
    }
}

// MARK: - Previews

#Preview("Active ghost") {
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
    .previewEnvironment(tunnels: manager)
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
