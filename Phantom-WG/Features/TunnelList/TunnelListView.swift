import SwiftUI
import UniformTypeIdentifiers

struct TunnelListView: View {
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc

    @State private var showingImport = false
    @State private var transferring = false
    @State private var showingFileImport = false
    @State private var transferNotice: TransferNotice?
    @State private var showingSearch = false
    @State private var savedOrder = TunnelListOrderStore.load()
    @State private var selecting = false
    @State private var deletion = TunnelDeleteSelection()
    #if DEBUG
    @State private var showingTestEngine = false
    #endif

    /// The tunnel the top section mirrors: the one holding the slot
    /// (`TunnelListRules.slotHolder`). `TunnelsManager` queues an
    /// activation behind the deactivation it starts, so during a
    /// hand-off one tunnel waits while another goes down; the section
    /// shows the one going down until its session ends. The list itself
    /// follows the user's order, not the slot — no active-first pinning;
    /// the top section is where the running tunnel surfaces.
    private var activeTunnel: TunnelContainer? {
        TunnelListRules.slotHolder(in: tunnelsManager.tunnels, status: \.status)
    }

    /// The rows in the user's order (`TunnelListRules.ordered`): newest
    /// first until a row is dragged, and a tunnel added since on top.
    private var ordered: [TunnelContainer] {
        TunnelListRules.ordered(tunnelsManager.tunnels, saved: savedOrder, id: \.id)
    }

    var body: some View {
        NavigationStack {
            listContent
                .navigationTitle(loc.t("app_title"))
                .toolbar { toolbarContent }
                .navigationDestination(isPresented: $showingImport) {
                    TunnelImportView()
                }
                .navigationDestination(isPresented: $showingSearch) {
                    TunnelSearchView(order: savedOrder)
                }
                .onChange(of: tunnelsManager.tunnels.isEmpty) { _, empty in
                    if empty { selecting = false }
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
                .fileImporter(
                    isPresented: $showingFileImport,
                    allowedContentTypes: [.zip, .data],
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case .success(let urls):
                        if !urls.isEmpty { importFiles(urls) }
                    case .failure(let error):
                        transferNotice = TransferNotice(title: loc.t("error"), message: error.localizedDescription)
                    }
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
                // A row is deleted by swiping it left
                // (`TunnelListSection`) or from the detail's Actions
                // section.
                Form {
                    ActiveTunnelSection(activeTunnel: activeTunnel)

                    if selecting {
                        TunnelDeleteSection(
                            rows: ordered,
                            selection: deletion,
                            onFinish: report(deleted:),
                            onFailure: { transferNotice = TransferNotice(title: loc.t("error"), message: $0) }
                        )
                    } else {
                        TunnelListSection(
                            rows: ordered,
                            count: "\(tunnelsManager.tunnels.count)",
                            onMove: { offsets, destination in
                                reorder(TunnelListRules.moved(ordered.map(\.id), from: offsets, to: destination))
                            },
                            onStep: { id, up in
                                reorder(TunnelListRules.movedByOne(ordered.map(\.id), id, up: up))
                            },
                            onSelect: {
                                deletion = TunnelDeleteSelection()
                                selecting = true
                            }
                        )
                    }
                }
                .formStyle(.grouped)
                .safeAreaInset(edge: .bottom) {
                    if selecting {
                        TunnelDeleteBar(rows: ordered, selection: deletion, onCancel: { selecting = false })
                    }
                }

                // The delete selection's bar takes the bottom edge while it
                // is open.
                if !selecting {
                    Divider()

                    bottomLinks
                }
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
            Button {
                showingSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .disabled(tunnelsManager.tunnels.isEmpty || selecting)
            .accessibilityLabel(loc.t("tunnel_list_search_placeholder"))
            .accessibilityIdentifier(AXID.TunnelList.searchButton)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showingFileImport = true
                } label: {
                    Label(loc.t("settings_import_tunnels"), systemImage: "square.and.arrow.down")
                }
                .disabled(transferring)
                .accessibilityIdentifier(AXID.TunnelList.importFilesButton)
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

    // MARK: - Order

    /// Keeps the order a drag or a step left, at once and across launches.
    private func reorder(_ order: [UUID]) {
        savedOrder = order
        TunnelListOrderStore.save(order)
    }

    // MARK: - Delete

    /// Ends the selection with its report: a whole delete is told in the
    /// title, a partial one names each row left and why.
    private func report(deleted report: TunnelBulkDelete.Report) {
        selecting = false
        transferNotice = report.skipped.isEmpty
            ? TransferNotice(title: loc.t("delete_report_success", report.deleted.count), message: "")
            : TransferNotice(title: TunnelBulkDelete.title(report, loc: loc), message: TunnelBulkDelete.message(report, loc: loc))
    }

    // MARK: - Import

    /// Reads every picked file that is not a zip archive, and every `.conf`
    /// entry inside the picked zip archives, as a `.conf`; adds what
    /// validates and reports what was added and what was not.
    private func importFiles(_ urls: [URL]) {
        transferring = true
        Task {
            let report = await TunnelBulkImport.run(urls, into: tunnelsManager)
            transferring = false
            transferNotice = report.skipped.isEmpty
                ? TransferNotice(title: loc.t("import_report_success", report.added.count), message: "")
                : TransferNotice(title: TunnelBulkImport.title(report, loc: loc),
                                 message: TunnelBulkImport.message(report, loc: loc))
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
