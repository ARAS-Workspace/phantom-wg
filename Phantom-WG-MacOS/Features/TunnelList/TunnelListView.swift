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

                tunnelsManager.suspendRefreshForUninstall()
                defer { tunnelsManager.releaseStoreAfterUninstall() }

                let removableIds = await tunnelsManager.removableEntryIds()

                await tunnelsManager.disarmAllRecovery()

                await sessionCoordinator.purgeForUninstall()

                try await gateCoordinator.uninstallAll()

                await tunnelsManager.removeEntriesForUninstall(removableIds)
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
