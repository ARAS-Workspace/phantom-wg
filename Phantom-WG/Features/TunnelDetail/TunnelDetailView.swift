import SwiftUI

/// Tunnel detail — read-only presentation of the saved configuration
/// plus live status, stats, and logs. The configuration is read
/// synchronously off the provider's Keychain reference, so the
/// sections render instantly; `nil` means the Keychain entry itself
/// is gone. Editing happens as raw text in `TunnelEditView`
/// (Actions → Edit Config), enabled only while the tunnel is
/// inactive — the macOS flow.
struct TunnelDetailView: View {
    var tunnel: TunnelContainer
    @State var logStore: LogStore
    @Environment(TunnelsManager.self) var tunnelsManager
    @Environment(LocalizationManager.self) var loc
    @Environment(\.dismiss) var dismiss

    /// Live read — stays current across edits without any reload
    /// choreography because the provider is the storage.
    var config: TunnelConfig? { tunnel.tunnelConfig }

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
        // A grouped form to match the macOS presentation — every
        // screen on both platforms renders in one.
        Form {
            StatusSection(tunnel: tunnel, isGhost: tunnel.isGhost)

            StatsSection(handshake: lastHandshake, rxBytes: rxBytes, txBytes: txBytes)

            OnDemandSection(onDemandEnabled: onDemandBinding)

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
        .navigationBarTitleDisplayMode(.inline)
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
        .alert(loc.t("detail_delete_confirm_title"),
               isPresented: $showingDeleteConfirmation) {
            Button(loc.t("cancel"), role: .cancel) {}
                .accessibilityIdentifier(AXID.TunnelDetail.Actions.deleteCancel)
            Button(loc.t("delete"), role: .destructive) { deleteTunnel() }
                .accessibilityIdentifier(AXID.TunnelDetail.Actions.deleteConfirm)
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
        } else {
            Section {
                Label(loc.t("detail_config_unavailable"), systemImage: "lock.slash")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AXID.TunnelDetail.configUnavailable)
            }
        }
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
}

#Preview("Inactive standalone") {
    let manager = PreviewFixtures.tunnelsManager(providers: [
        PreviewFixtures.provider(config: PreviewFixtures.wireguardConfig())
    ])
    return NavigationStack {
        TunnelDetailView(tunnel: manager.tunnels[0])
    }
    .previewEnvironment(tunnels: manager)
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
}
