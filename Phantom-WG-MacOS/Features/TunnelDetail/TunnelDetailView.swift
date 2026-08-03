import SwiftUI

/// Tunnel detail — read-only structured presentation of the saved
/// configuration plus live status, stats, and logs. Following the
/// WireGuard app pattern, the configuration is edited as raw text in
/// `TunnelEditView` (Actions → Edit Config) and never field-by-field
/// here; the edit entry is only enabled while the tunnel is inactive.
struct TunnelDetailView: View {
    var tunnel: TunnelContainer
    @State private var logStore: LogStore
    @Environment(TunnelsManager.self) var tunnelsManager
    @Environment(LocalizationManager.self) var loc
    @Environment(\.dismiss) var dismiss

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
        let config = tunnel.tunnelConfig
        List {
            StatusSection(tunnel: tunnel, isGhost: config?.isGhostMode == true)

            StatsSection(handshake: lastHandshake, rxBytes: rxBytes, txBytes: txBytes)

            if let config {
                NameSection(name: config.name)

                if let wstunnel = config.wstunnel {
                    WstunnelSection(config: wstunnel)
                }

                InterfaceSection(config: config.wireguard.interface)

                PeerSection(config: config.wireguard.peer)
            }

            LogNavigationSection(logStore: logStore)

            ActionsSection(
                tunnel: tunnel,
                copyAction: copyConf,
                editAction: { showingEdit = true },
                resetAction: resetConnection,
                showingDeleteConfirmation: $showingDeleteConfirmation
            )
        }
        .navigationTitle(tunnel.name.isEmpty ? loc.t("detail_tunnel") : tunnel.name)
        .navigationDestination(isPresented: $showingEdit) {
            TunnelEditView(tunnel: tunnel)
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
    .frame(width: 480, height: 720)
}

#Preview("Inactive standalone") {
    let manager = PreviewFixtures.tunnelsManager(providers: [
        PreviewFixtures.provider(config: PreviewFixtures.wireguardConfig())
    ])
    return NavigationStack {
        TunnelDetailView(tunnel: manager.tunnels[0])
    }
    .previewEnvironment(tunnels: manager)
    .frame(width: 480, height: 720)
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
    .frame(width: 480, height: 720)
}
