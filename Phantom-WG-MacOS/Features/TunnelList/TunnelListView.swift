import SwiftUI

struct TunnelListView: View {
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ExtensionGateCoordinator.self) private var gateCoordinator

    @State private var showingImport = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var showingUninstallConfirm = false
    @State private var showingSplitTunneling = false
    @State private var uninstalling = false

    /// The tunnel the top section mirrors. `TunnelsManager` enforces a
    /// single non-inactive tunnel at a time (activation queues behind
    /// deactivation), so "first non-inactive" is the whole story. The
    /// list itself stays in plain newest-first order — no active-first
    /// pinning; the top section is where the running tunnel surfaces.
    private var activeTunnel: TunnelContainer? {
        tunnelsManager.tunnels.first { $0.status != .inactive }
    }

    var body: some View {
        NavigationStack {
            listContent
                .navigationTitle(loc.t("app_title"))
                .toolbar { toolbarContent }
                .navigationDestination(isPresented: $showingImport) {
                    TunnelImportView()
                }
                .sheet(isPresented: $showingSplitTunneling) {
                    NavigationStack {
                        SplitTunnelingView()
                    }
                }
                .modifier(UninstallAlerts(
                    errorMessage: $errorMessage,
                    showingError: $showingError,
                    showingUninstallConfirm: $showingUninstallConfirm,
                    onConfirm: runUninstall
                ))
                .disabled(uninstalling)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if tunnelsManager.tunnels.isEmpty {
            EmptyStateView(showingImport: $showingImport)
        } else {
            VStack(spacing: 0) {
                // A grouped form on purpose — List's NSTableView
                // bridge intermittently left a phantom band around
                // the header after a navigation pop when content
                // changed while the screen was covered. Forms never
                // showed it anywhere in the app. Keep it a Form.
                Form {
                    ActiveTunnelSection(activeTunnel: activeTunnel)

                    Section {
                        ForEach(tunnelsManager.tunnels) { tunnel in
                            NavigationLink(destination: TunnelDetailView(tunnel: tunnel)) {
                                TunnelRow(tunnel: tunnel)
                            }
                        }
                    } header: {
                        HStack {
                            Label(loc.t("tunnel_list_section_header"), systemImage: "list.bullet")
                            Spacer()
                            Text("\(tunnelsManager.tunnels.count)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.15))
                                )
                                .accessibilityIdentifier(AXID.TunnelList.listCount)
                        }
                        .padding(.bottom, 6)
                    }
                }
                .formStyle(.grouped)

                Divider()

                bottomLinks
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            SettingsMenu(
                showingUninstallConfirm: $showingUninstallConfirm,
                showingSplitTunneling: $showingSplitTunneling,
                isUninstalling: uninstalling
            )
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingImport = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityIdentifier(AXID.TunnelList.addButton)
        }
    }

    /// Fixed footer — the form above scrolls as it grows inside the
    /// app's fixed window, the links stay put. Mirrors the empty
    /// state's bottom-link styling.
    private var bottomLinks: some View {
        HStack(spacing: 24) {
            Link(destination: URL(string: "https://www.phantom.tc")!) {
                Label(loc.t("website"), systemImage: "globe")
                    .font(.footnote)
            }
            Link(destination: URL(string: "https://www.phantom.tc/docs")!) {
                Label(loc.t("documentation"), systemImage: "book")
                    .font(.footnote)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Uninstall

    private func runUninstall() {
        uninstalling = true
        Task {
            do {
                // The vault empties first, while the tunnel extension
                // is still there to answer — deactivation removes the
                // XPC peer. A failed purge stops the uninstall whole:
                // better than reporting clean while secrets stay in
                // the System keychain. The cost of the ordering: once
                // the purge has run, cancelling the deactivation that
                // follows does not bring the tunnels back.
                try await tunnelsManager.purgeVault()

                // Sequential deactivation of all three system
                // extensions (Tunnel + Split-Tunnel + DNSProxy).
                // VPN configurations stored in
                // NETunnelProviderManager preferences are left in
                // place: every `removeFromPreferences` triggers an
                // "Allow VPN Configurations" consent prompt with no
                // API to batch them; without the system extensions
                // the configurations are inert — and should the
                // extensions ever return, reconcile clears the
                // now-unbacked entries. On success every
                // controller settles to `.notInstalled`,
                // `coordinator.allReady` flips to false and
                // `PhantomApp` falls back to `ExtensionGateView`.
                try await gateCoordinator.uninstallAll()
                uninstalling = false
            } catch {
                uninstalling = false
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}

// MARK: - Previews

#Preview("Tunnels — Light") {
    TunnelListView()
        .previewEnvironment(scheme: .light)
        .frame(width: 560, height: 720)
}

#Preview("Tunnels — Dark") {
    TunnelListView()
        .previewEnvironment(scheme: .dark)
        .frame(width: 560, height: 720)
}

#Preview("No active tunnel") {
    TunnelListView()
        .previewEnvironment(tunnels: PreviewFixtures.tunnelsManager(providers: [
            PreviewFixtures.provider(config: PreviewFixtures.wireguardConfig()),
            PreviewFixtures.provider(config: PreviewFixtures.ghostConfig(name: "Home Lab"))
        ]))
        .frame(width: 560, height: 720)
}

#Preview("Empty") {
    TunnelListView()
        .previewEnvironment(tunnels: PreviewFixtures.tunnelsManager(providers: []))
        .frame(width: 560, height: 720)
}
