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
    @State private var transferring = false
    @State private var transferNotice: TransferNotice?
    @State private var transferToasts = ToastCenter()
    #if DEBUG
    @State private var showingTestEngine = false
    #endif

    var body: some View {
        NavigationStack {
            listContent
                .toastOverlay(transferToasts)
                .navigationTitle(loc.t("app_title"))
                .toolbar { toolbarContent }
                .navigationDestination(isPresented: $showingImport) {
                    TunnelImportView()
                }
                .sheet(isPresented: $showingSplitTunneling) {
                    NavigationStack {
                        SplitTunnelingView()
                    }
                    .presentationSizing(.page.fitted(horizontal: true, vertical: false))
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
                .alert(
                    transferNotice?.title ?? "",
                    isPresented: Binding(
                        get: { transferNotice != nil },
                        set: { if !$0 { transferNotice = nil } }
                    )
                ) {
                    Button(loc.t("ok")) {}
                        .accessibilityIdentifier(AXID.TunnelList.importReportOK)
                } message: {
                    Text(transferNotice?.message ?? "")
                }
                .disabled(uninstalling)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if tunnelsManager.tunnels.isEmpty {
            EmptyStateView(showingImport: $showingImport)
        } else {
            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    ActiveTunnelSection()
                    TunnelListSection()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

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
                isTransferring: transferring,
                canExport: !tunnelsManager.tunnels.isEmpty,
                onImport: importFromFiles,
                onExport: exportToZip,
                showingTestEngine: $showingTestEngine
            )
            #else
            SettingsMenu(
                showingUninstallConfirm: $showingUninstallConfirm,
                showingSplitTunneling: $showingSplitTunneling,
                isUninstalling: uninstalling,
                isTransferring: transferring,
                canExport: !tunnelsManager.tunnels.isEmpty,
                onImport: importFromFiles,
                onExport: exportToZip
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

    // MARK: - Import

    private func importFromFiles() {
        let panel = NSOpenPanel()
        panel.title = loc.t("settings_import_tunnels")
        panel.prompt = loc.t("import_button")
        panel.allowedContentTypes = [TunnelConfFile.contentType, .zip]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let urls = panel.urls
        transferring = true
        Task {
            let report = await TunnelBulkImport.run(urls, into: tunnelsManager)
            transferring = false
            if report.skipped.isEmpty {
                transferToasts.success(loc.t("import_report_success", report.added.count))
            } else {
                transferNotice = TransferNotice(
                    title: TunnelBulkImport.title(report, loc: loc),
                    message: TunnelBulkImport.message(report, loc: loc)
                )
            }
        }
    }

    // MARK: - Export

    private func exportToZip() {
        Task {
            let granted = await PrivateDataGuard.grants(reason: loc.t("export_private_data_reason")) { message in
                transferNotice = TransferNotice(title: loc.t("error"), message: message)
            }
            guard granted else { return }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = TunnelExportBatch.defaultFileName
            panel.canCreateDirectories = true
            panel.title = loc.t("settings_export_tunnels")

            guard panel.runModal() == .OK, let url = panel.url else { return }

            transferring = true
            let outcome = await TunnelBulkExport.run(tunnelsManager.tunnels, vault: tunnelsManager.vault, to: url)
            transferring = false
            present(outcome)
        }
    }

    private func present(_ outcome: TunnelBulkExport.Outcome) {
        switch outcome {
        case .exported(let count, _, let unread) where unread.isEmpty:
            transferToasts.success(loc.t("export_report_success", count))
        case .exported(let count, let total, let unread):
            transferNotice = TransferNotice(
                title: loc.t("export_report_partial", count, total),
                message: TunnelBulkExport.unreadLines(unread, loc: loc)
            )
        case .nothing(let unread):
            transferNotice = TransferNotice(
                title: loc.t("export_report_none"),
                message: TunnelBulkExport.unreadLines(unread, loc: loc)
            )
        case .vaultUnavailable:
            transferNotice = TransferNotice(
                title: loc.t("error"),
                message: TunnelManagementError.vaultUnavailable.localizedDescription
            )
        case .unwritable:
            transferNotice = TransferNotice(title: loc.t("error"), message: loc.t("export_err_write"))
        }
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

private struct TransferNotice {
    let title: String
    let message: String
}

// MARK: - Previews

#Preview("Tunnels — Light") {
    TunnelListView()
        .previewEnvironment(scheme: .light)
        .frame(width: WindowSizing.ideal.width, height: WindowSizing.ideal.height)
}

#Preview("Tunnels — Dark") {
    TunnelListView()
        .previewEnvironment(scheme: .dark)
        .frame(width: WindowSizing.ideal.width, height: WindowSizing.ideal.height)
}

#Preview("Tunnels — WireGuard + Ghost") {
    TunnelListView()
        .previewEnvironment(tunnels: PreviewFixtures.tunnelsManager(providers: [
            PreviewFixtures.provider(config: PreviewFixtures.wireguardConfig()),
            PreviewFixtures.provider(config: PreviewFixtures.ghostConfig(name: "Home Lab"))
        ]))
        .frame(width: WindowSizing.ideal.width, height: WindowSizing.ideal.height)
}

#Preview("Empty") {
    TunnelListView()
        .previewEnvironment(tunnels: PreviewFixtures.tunnelsManager(providers: []))
        .frame(width: WindowSizing.ideal.width, height: WindowSizing.ideal.height)
}
