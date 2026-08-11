import SwiftUI

struct TunnelListView: View {
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ExtensionGateCoordinator.self) private var gateCoordinator
    @Environment(SplitTunnelingSessionCoordinator.self) private var sessionCoordinator

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
                // No "active tunnel" summary here, unlike iOS. Under
                // the ingest ownership boundary every row is already
                // this user's, so a summary could only repeat what
                // each row's status shows — while the machine-wide
                // question ("is a VPN up on this Mac?") can truthfully
                // be about another local user's session. That story
                // belongs to the connection gate, which names a
                // foreign holder only on the classifier's positive
                // proof and at the moment it matters — when the slot
                // blocks this user's activation — not to a passive
                // banner guessing about someone else's session. iOS
                // is single-user, so it keeps the summary.
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
                // Uninstall removes what the SYSTEM holds, never what
                // the USER made: extensions deactivate and this user's
                // VPN entries leave System Settings, while tunnel
                // configurations and keys stay in the vault (and the
                // split-tunneling list in its App Group file) — a
                // reinstall brings everything back. Destroying
                // configurations is the user's own act, in the app,
                // before this flow.

                // Classify while the vault still answers: only the
                // entries whose payloads provably DECODE today are
                // removable — that is exactly the set reinstall's
                // reconcile restores. A custody row (payload present
                // but undecodable) keeps its entry on purpose: the
                // entry is the sole anchor that makes the broken
                // payload visible again after a reinstall.
                let removableIds = await tunnelsManager.removableEntryIds()

                // Recovery rules stand down first: an armed rule on an
                // entry would keep asking the system to revive a
                // tunnel whose extension is about to be gone.
                await tunnelsManager.disarmAllRecovery()

                // The teardown owns the store from here. Entry
                // removals fire configuration-change bursts, and a
                // debounced reload sampling the vault mid-teardown
                // would resurrect what this flow removes (reconcile
                // restores any answered payload missing its entry).
                tunnelsManager.suspendRefreshForUninstall()

                // Split-tunneling: the running session stops and both
                // proxy preference entries go — NE-side holdings. The
                // App Group configuration file stays: it is the user's
                // list, and a reinstall picks it back up.
                await sessionCoordinator.purgeForUninstall()

                // Sequential deactivation of all three system
                // extensions (Tunnel + Split-Tunnel + DNSProxy). On
                // success every controller settles to `.notInstalled`,
                // `coordinator.allReady` flips false and `PhantomApp`
                // falls back to `ExtensionGateView` while this task
                // finishes the cleanup below.
                try await gateCoordinator.uninstallAll()

                // LAST, with the extensions down: this user's
                // removable entries leave the system store, matched
                // against a FRESH system list so even an entry a
                // mid-teardown pass managed to mint is caught. The
                // refresh latch is the load-bearing guarantee here —
                // this process runs no reconcile that could restore
                // the removals — with the vault daemon's death as the
                // second wall (a reboot-pending deactivation can
                // leave the daemon answering until restart).
                await tunnelsManager.removeEntriesForUninstall(removableIds)
                uninstalling = false
            } catch {
                // A failed teardown leaves this process in list-world
                // with its entries intact; the latch must not outlive
                // the flow it was raised for, or every self-heal
                // stays dead until relaunch.
                tunnelsManager.resumeRefresh()
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

#Preview("Tunnels — WireGuard + Ghost") {
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
