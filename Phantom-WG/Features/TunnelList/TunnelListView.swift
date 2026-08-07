import SwiftUI

struct TunnelListView: View {
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc

    @State private var showingImport = false

    /// The tunnel the top section mirrors. One non-inactive tunnel at
    /// a time: `TunnelsManager` queues activation behind deactivation,
    /// and the OS's single-enabled-configuration rule backs the same
    /// invariant from below — so "first non-inactive" is the whole
    /// story. The list itself stays in plain newest-first order — no
    /// active-first pinning; the top section is where the running
    /// tunnel surfaces.
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
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if tunnelsManager.tunnels.isEmpty {
            EmptyStateView(showingImport: $showingImport)
        } else {
            VStack(spacing: 0) {
                // A grouped form to match the macOS presentation —
                // every screen on both platforms renders in one.
                // Deleting happens in the detail's Actions section,
                // not by swiping rows, mirroring the macOS flow.
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
        ToolbarItem(placement: .topBarLeading) {
            LanguageToggleButton()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingImport = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityIdentifier(AXID.TunnelList.addButton)
        }
    }

    /// Fixed footer — the form above scrolls as it grows, the links
    /// stay put. Mirrors the empty state's bottom-link styling.
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
}

// MARK: - Previews

#Preview("Tunnels — Light") {
    TunnelListView()
        .previewEnvironment(scheme: .light)
}

#Preview("Tunnels — Dark") {
    TunnelListView()
        .previewEnvironment(scheme: .dark)
}

#Preview("No active tunnel") {
    TunnelListView()
        .previewEnvironment(tunnels: PreviewFixtures.tunnelsManager(providers: [
            PreviewFixtures.provider(config: PreviewFixtures.wireguardConfig()),
            PreviewFixtures.provider(config: PreviewFixtures.ghostConfig(name: "Home Lab"))
        ]))
}

#Preview("Empty") {
    TunnelListView()
        .previewEnvironment(tunnels: PreviewFixtures.tunnelsManager(providers: []))
}
