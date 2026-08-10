import SwiftUI

struct TunnelListView: View {
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ExtensionGateCoordinator.self) private var gateCoordinator
    @Environment(SplitTunnelingSessionCoordinator.self) private var sessionCoordinator
    @Environment(SplitTunnelingStore.self) private var splitTunnelingStore

    @State private var showingImport = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var showingUninstallConfirm = false
    @State private var showingSplitTunneling = false
    @State private var uninstalling = false
    #if DEBUG
    @State private var showingTestEngine = false
    #endif

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
                #if DEBUG
                .sheet(isPresented: $showingTestEngine) {
                    TestEngineView()
                }
                #endif
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
                // No "active tunnel" summary here, unlike iOS. On macOS
                // the system extension and its NE configurations are
                // system-wide, so a "currently active" line could
                // truthfully belong to another local user's VPN — one
                // this app is deliberately scoped out of. Rather than
                // print a value that might be about someone else's
                // session, we drop the claim entirely: this per-user
                // list is the whole operator surface, and the machine's
                // system-wide VPN state stays where it belongs, in
                // System Settings > VPN. iOS is single-user, so it
                // keeps the summary.
                //
                // A grouped form on purpose — List's NSTableView
                // bridge intermittently left a phantom band around
                // the header after a navigation pop when content
                // changed while the screen was covered. Forms never
                // showed it anywhere in the app. Keep it a Form.
                Form {
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
            #if DEBUG
            SettingsMenu(
                showingUninstallConfirm: $showingUninstallConfirm,
                showingSplitTunneling: $showingSplitTunneling,
                isUninstalling: uninstalling,
                showingTestEngine: $showingTestEngine
            )
            #else
            SettingsMenu(
                showingUninstallConfirm: $showingUninstallConfirm,
                showingSplitTunneling: $showingSplitTunneling,
                isUninstalling: uninstalling
            )
            #endif
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
                // Recovery rules stand down before anything else: the
                // tunnel entries stay behind after uninstall, and an
                // armed rule on an orphaned entry would keep asking
                // the system to revive a tunnel whose extension is
                // about to be gone.
                await tunnelsManager.disarmAllRecovery()

                // The vault empties next, while the tunnel extension
                // is still there to answer — deactivation removes the
                // XPC peer. A failed purge stops the uninstall whole:
                // better than reporting clean while secrets stay in
                // the System keychain. The cost of the ordering: once
                // the purge has run, cancelling the deactivation that
                // follows does not bring the tunnels back.
                try await tunnelsManager.purgeVault()

                // Split-tunneling leaves nothing behind either: the
                // running session stops, both proxy preference entries
                // and the App Group config file are deleted —
                // best-effort, since whatever survives is exactly what
                // the uninstall copy tells the user to remove by hand.
                await sessionCoordinator.purgeForUninstall()
                splitTunnelingStore.purgePersistedConfiguration()

                // Sequential deactivation of all three system
                // extensions (Tunnel + Split-Tunnel + DNSProxy).
                // Tunnel (VPN) configurations stored in
                // NETunnelProviderManager preferences are the one
                // thing left in place: every `removeFromPreferences`
                // triggers an "Allow VPN Configurations" consent
                // prompt with no API to batch them; without the
                // system extensions the configurations are inert —
                // and should the extensions ever return, reconcile
                // clears the now-unbacked entries. On success every
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
