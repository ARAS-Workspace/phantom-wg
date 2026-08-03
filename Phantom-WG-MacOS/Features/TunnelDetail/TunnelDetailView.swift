import SwiftUI

/// Tunnel detail + editor. Orchestrates the draft/original/errors
/// state machine and dispatches each visual slice to a dedicated
/// section view. Field edits are validated on commit (Enter on any
/// field); invalid commits revert the draft and surface per-field
/// errors for a short grace period.
struct TunnelDetailView: View {
    var tunnel: TunnelContainer
    @State private var logStore: LogStore
    @Environment(TunnelsManager.self) var tunnelsManager
    @Environment(LocalizationManager.self) var loc
    @Environment(\.dismiss) var dismiss

    @State var draft: TunnelDraft = .empty()
    @State var originalDraft: TunnelDraft = .empty()
    @State var fieldErrors: [TunnelDraft.Field: FieldValidationError] = [:]
    @State var fieldErrorClearTask: Task<Void, Never>?
    /// Distinguishes a programmatic revert (rejection of an invalid
    /// commit) from a user edit. Set to `true` just before reverting
    /// the draft; the next `onChange(of: draft)` consumes and resets it.
    @State var programmaticRevert: Bool = false
    @State var showingDeleteConfirmation = false
    @State var errorMessage: String?
    @State var showingError = false

    // Stats
    @State var lastHandshake: String = "—"
    @State var rxBytes: String = "—"
    @State var txBytes: String = "—"
    @State var statsPollingTask: Task<Void, Never>?

    /// Config fields are only editable while the tunnel is inactive.
    var isEditable: Bool { tunnel.status == .inactive }

    init(tunnel: TunnelContainer) {
        self.tunnel = tunnel
        _logStore = State(wrappedValue: LogStore(tunnel: tunnel))
    }

    var body: some View {
        List {
            StatusSection(tunnel: tunnel, isGhost: draft.wstunnel != nil)

            StatsSection(handshake: lastHandshake, rxBytes: rxBytes, txBytes: txBytes)

            NameSection(
                name: $draft.name,
                isEditable: isEditable,
                errorMessage: fieldErrors[.name]?.localizedMessage(loc)
            )

            if let wstunnelBinding = Binding($draft.wstunnel) {
                WstunnelSection(
                    draft: wstunnelBinding,
                    isEditable: isEditable,
                    fieldErrors: fieldErrors
                )
            }

            InterfaceSection(
                draft: $draft.wireguard.interface,
                isEditable: isEditable,
                fieldErrors: fieldErrors
            )

            PeerSection(
                draft: $draft.wireguard.peer,
                isEditable: isEditable,
                fieldErrors: fieldErrors
            )

            LogNavigationSection(logStore: logStore)

            ActionsSection(
                tunnel: tunnel,
                copyAction: copyConf,
                resetAction: resetConnection,
                showingDeleteConfirmation: $showingDeleteConfirmation
            )
        }
        .navigationTitle(draft.name.isEmpty ? loc.t("detail_tunnel") : draft.name)
        .onChange(of: draft) { _, _ in
            // Skip the clearing side-effect when the change originated
            // from a programmatic revert (invalid commit rollback) so
            // the accompanying error banner can still be seen.
            if programmaticRevert {
                programmaticRevert = false
                return
            }
            // User edit: drop stale errors and cancel the auto-dismiss
            // timer — the next commit re-validates the full draft.
            if !fieldErrors.isEmpty {
                fieldErrors = [:]
                fieldErrorClearTask?.cancel()
                fieldErrorClearTask = nil
            }
        }
        .onSubmit {
            // Native form commit: when any field's Enter fires, validate
            // the draft and persist if it's clean. Invalid fields show
            // their errors inline; the draft itself remains editable.
            commitDraft()
        }
        .onAppear {
            loadDraft()
            logStore.startPolling()
            if tunnel.status == .active { startStatsPolling() }
        }
        .onDisappear {
            logStore.stopPolling()
            stopStatsPolling()
            fieldErrorClearTask?.cancel()
            fieldErrorClearTask = nil
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
