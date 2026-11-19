import SwiftUI

struct TunnelListView: View {
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc

    @State private var showingImport = false
    @State private var transferring = false
    @State private var transferNotice: TransferNotice?
    #if DEBUG
    @State private var showingTestEngine = false
    #endif

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
                .alert(
                    transferNotice?.title ?? "",
                    isPresented: Binding(
                        get: { transferNotice != nil },
                        set: { if !$0 { transferNotice = nil } }
                    )
                ) {
                    Button(loc.t("ok")) {}
                        .accessibilityIdentifier(AXID.TunnelList.transferNoticeOK)
                } message: {
                    Text(transferNotice?.message ?? "")
                }
                #if DEBUG
                .sheet(isPresented: $showingTestEngine) {
                    TestEngineView()
                }
                .task {
                    PhantomTestEngine.shared.autorunIfRequested(TestContext(tunnels: tunnelsManager))
                }
                #endif
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
        #if DEBUG
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showingTestEngine = true
            } label: {
                Image(systemName: "ladybug")
            }
            .accessibilityLabel(TestEngineStrings.of(loc.current).menuEntry)
        }
        #endif
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(action: exportAll) {
                    Label(loc.t("settings_export_tunnels"), systemImage: "square.and.arrow.up")
                }
                .disabled(transferring || tunnelsManager.tunnels.isEmpty)
                .accessibilityIdentifier(AXID.TunnelList.exportAllButton)
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel(loc.t("transfer_menu"))
            .accessibilityIdentifier(AXID.TunnelList.transferMenu)
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

    // MARK: - Export

    /// Archives every readable tunnel once the owner grants it and hands
    /// the zip to the export picker; the report follows a save.
    private func exportAll() {
        transferring = true
        Task {
            let outcome = await TunnelBulkExport.run(tunnelsManager.tunnels, reason: loc.t("export_private_data_reason")) { message in
                transferNotice = TransferNotice(title: loc.t("error"), message: message)
            }
            switch outcome {
            case .archived(let file, let count, let total, let unread):
                present(file) { saved in
                    guard saved else { return }
                    transferNotice = unread.isEmpty
                        ? TransferNotice(title: loc.t("export_report_success", count), message: "")
                        : TransferNotice(title: loc.t("export_report_partial", count, total),
                                         message: TunnelBulkExport.unreadLines(unread, loc: loc))
                }
            case .nothing(let unread):
                transferring = false
                transferNotice = TransferNotice(title: loc.t("export_report_none"),
                                                message: TunnelBulkExport.unreadLines(unread, loc: loc))
            case .unwritable:
                transferring = false
                transferNotice = TransferNotice(title: loc.t("error"), message: loc.t("export_err_write"))
            case .declined:
                transferring = false
            }
        }
    }

    private func present(_ file: ExportedFile, onSaved: @escaping (Bool) -> Void) {
        let exporter = TunnelExportPicker { saved in
            transferring = false
            onSaved(saved)
        }
        guard let presenter = TunnelExportPicker.topViewController() else {
            transferring = false
            return
        }
        do {
            try exporter.present(file, over: presenter)
        } catch {
            transferring = false
            transferNotice = TransferNotice(title: loc.t("error"), message: error.localizedDescription)
        }
    }

    /// Fixed footer — the form above scrolls as it grows, the links
    /// stay put. Mirrors the empty state's bottom-link styling.
    ///
    /// The line above the links is the declaration itself, not a link to
    /// one: it sits on the first screen, before a tunnel has been
    /// imported or started, so what the app does with data is answered
    /// where the reader already is rather than behind a tap.
    private var bottomLinks: some View {
        VStack(spacing: 8) {
            Text(loc.t("privacy_notice"))
                .font(.caption2)

            HStack(spacing: 24) {
                Link(destination: URL(string: "https://www.phantom.tc")!) {
                    Label(loc.t("website"), systemImage: "globe")
                        .font(.footnote)
                }
                Link(destination: URL(string: "https://www.phantom.tc/docs")!) {
                    Label(loc.t("documentation"), systemImage: "book")
                        .font(.footnote)
                }
                if let policy = loc.privacyPolicyURL {
                    Link(destination: policy) {
                        Label(loc.t("privacy"), systemImage: "hand.raised")
                            .font(.footnote)
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// A transfer's report or failure, shown as an alert.
private struct TransferNotice {
    let title: String
    let message: String
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
