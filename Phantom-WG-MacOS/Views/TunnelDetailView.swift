import SwiftUI

struct TunnelDetailView: View {
    @ObservedObject var tunnel: TunnelContainer
    @StateObject private var logStore: LogStore
    @EnvironmentObject var tunnelsManager: TunnelsManager
    @EnvironmentObject var loc: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    @State private var editConfig: TunnelConfig = .empty()
    @State private var originalConfig: TunnelConfig = .empty()
    @State private var showingDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var copiedItem: String?

    // Stats
    @State private var lastHandshake: String = "—"
    @State private var rxBytes: String = "—"
    @State private var txBytes: String = "—"
    @State private var statsPollingTask: Task<Void, Never>?

    /// Engine'den türetilen convenience — tüm field disabled/enabled kararları buradan
    private var isEditable: Bool { PhantomUIEngine.canEditConfig(status: tunnel.status) }

    init(tunnel: TunnelContainer) {
        self.tunnel = tunnel
        _logStore = StateObject(wrappedValue: LogStore(tunnel: tunnel))
    }

    var body: some View {
        List {
            statusSection
            if PhantomUIEngine.shouldShowStats(status: tunnel.status) { statsSection }
            nameSection
            wstunnelSection
            interfaceSection
            peerSection
            logSection
            actionsSection
        }
        .navigationTitle(editConfig.name.isEmpty ? loc.t("detail_tunnel") : editConfig.name)
        .onChange(of: editConfig) { _, newConfig in
            if PhantomUIEngine.shouldAutoSave(
                status: tunnel.status,
                hasChanges: newConfig != originalConfig
            ) {
                saveConfig()
            }
        }
        .onAppear {
            loadConfig()
            logStore.startPolling()
            if tunnel.status == .active { startStatsPolling() }
        }
        .onDisappear {
            logStore.stopPolling()
            stopStatsPolling()
        }
        .confirmationDialog(loc.t("detail_delete_confirm_title"),
                            isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button(loc.t("delete"), role: .destructive) { deleteTunnel() }
            Button(loc.t("cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("detail_delete_confirm_message"))
        }
        .alert(loc.t("error"), isPresented: $showingError) {
            Button(loc.t("ok")) {}
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

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(PhantomUIEngine.statusColor(for: tunnel.status).opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: PhantomUIEngine.statusIcon(for: tunnel.status))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(PhantomUIEngine.statusColor(for: tunnel.status))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(tunnel.status.localizedDescription)
                        .font(.body.weight(.medium))
                        .foregroundStyle(PhantomUIEngine.statusColor(for: tunnel.status))
                    if let error = tunnel.lastActivationError {
                        Text(error.alertText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                Toggle("", isOn: PhantomUIEngine.tunnelToggleBinding(for: tunnel, manager: tunnelsManager))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        } header: {
            Label(loc.t("detail_status"), systemImage: "antenna.radiowaves.left.and.right")
        }
    }

    private var statsSection: some View {
        Section {
            StatRow(icon: "hand.wave", label: loc.t("detail_handshake"), value: lastHandshake)
            StatRow(icon: "arrow.down.circle", label: loc.t("detail_received"), value: rxBytes, valueColor: .green)
            StatRow(icon: "arrow.up.circle", label: loc.t("detail_sent"), value: txBytes, valueColor: .blue)
        } header: {
            Label(loc.t("detail_transfer"), systemImage: "chart.bar.fill")
        }
    }

    private var nameSection: some View {
        Section {
            PhantomTextField(label: loc.t("detail_name"), text: $editConfig.name, isDisabled: !isEditable)
        } header: {
            Label(loc.t("detail_general"), systemImage: "gearshape")
        }
    }

    private var wstunnelSection: some View {
        Section {
            PhantomTextField(label: loc.t("detail_server_url"), text: $editConfig.wstunnel.url, isDisabled: !isEditable)
            PhantomTextField(label: loc.t("detail_secret"), text: $editConfig.wstunnel.secret, isDisabled: !isEditable)
            PhantomNumericField(label: loc.t("detail_local_port"), value: $editConfig.wstunnel.localPort, isDisabled: !isEditable)
            PhantomTextField(label: loc.t("detail_remote_host"), text: $editConfig.wstunnel.remoteHost, isDisabled: !isEditable)
            PhantomNumericField(label: loc.t("detail_remote_port"), value: $editConfig.wstunnel.remotePort, isDisabled: !isEditable)
        } header: {
            Label(loc.t("detail_wstunnel"), systemImage: "network.badge.shield.half.filled")
        }
    }

    private var interfaceSection: some View {
        Section {
            PhantomTextField(label: loc.t("detail_private_key"), text: $editConfig.interface.privateKey, isDisabled: !isEditable)
            PhantomTextField(label: loc.t("detail_address"), text: $editConfig.interface.address, isDisabled: !isEditable)
            PhantomTextField(label: loc.t("detail_dns"), text: $editConfig.interface.dns, isDisabled: !isEditable)
            PhantomNumericField(label: loc.t("detail_mtu"), value: $editConfig.interface.mtu, isDisabled: !isEditable)
        } header: {
            Label(loc.t("detail_interface"), systemImage: "rectangle.connected.to.line.below")
        }
    }

    private var peerSection: some View {
        Section {
            PhantomTextField(label: loc.t("detail_public_key"), text: $editConfig.peer.publicKey, isDisabled: !isEditable)
            PhantomTextField(label: loc.t("detail_preshared_key"), text: presharedKeyBinding, isDisabled: !isEditable)
            PhantomTextField(label: loc.t("detail_allowed_ips"), text: $editConfig.peer.allowedIPs, isDisabled: !isEditable)
            PhantomTextField(label: loc.t("detail_endpoint"), text: $editConfig.peer.endpoint, isDisabled: !isEditable)
            PhantomNumericField(label: loc.t("detail_keepalive"), value: $editConfig.peer.persistentKeepalive, isDisabled: !isEditable)
        } header: {
            Label(loc.t("detail_peer"), systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    private var logSection: some View {
        Section {
            NavigationLink {
                LogView(logStore: logStore)
            } label: {
                HStack {
                    Label(loc.t("detail_logs"), systemImage: "text.justify.left")
                    Spacer()
                    Text("\(logStore.entries.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.15))
                        )
                }
            }
            .listRowSeparator(.hidden)
        }
    }

    private var actionsSection: some View {
        Section {
            copyButton(loc.t("detail_copy_json"), icon: "curlybraces", id: "json") { copyJSON() }
                .listRowSeparator(.hidden)

            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label(loc.t("detail_delete_tunnel"), systemImage: "trash")
            }
            .disabled(!PhantomUIEngine.canDeleteTunnel(status: tunnel.status))
            .listRowSeparator(.hidden)
        } header: {
            Label(loc.t("detail_actions"), systemImage: "ellipsis.circle")
        }
    }

    // MARK: - Copy Button

    private func copyButton(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            copiedItem = id
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copiedItem == id { copiedItem = nil }
            }
        } label: {
            Label(copiedItem == id ? loc.t("detail_copied") : title,
                  systemImage: copiedItem == id ? "checkmark.circle.fill" : icon)
            .foregroundStyle(copiedItem == id ? .green : .accentColor)
        }
    }

    // MARK: - Bindings

    private var presharedKeyBinding: Binding<String> {
        Binding(
            get: { editConfig.peer.presharedKey ?? "" },
            set: { editConfig.peer.presharedKey = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Actions

    private func loadConfig() {
        if let config = tunnel.tunnelConfig {
            editConfig = config
            originalConfig = config
        }
    }

    private func saveConfig() {
        Task {
            do {
                try await tunnelsManager.modify(tunnel: tunnel, with: editConfig)
                originalConfig = editConfig
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func copyJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(editConfig),
              let json = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }

    private func deleteTunnel() {
        if tunnel.status != .inactive {
            tunnelsManager.startDeactivation(of: tunnel)
        }
        Task {
            do {
                try await tunnelsManager.remove(tunnel: tunnel)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    // MARK: - Stats Polling

    private func startStatsPolling() {
        stopStatsPolling()
        pollStats()
        statsPollingTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                pollStats()
            }
        }
    }

    private func stopStatsPolling() {
        statsPollingTask?.cancel()
        statsPollingTask = nil
    }

    private func resetStats() {
        lastHandshake = "—"
        rxBytes = "—"
        txBytes = "—"
    }

    private func pollStats() {
        guard tunnel.status == .active else { return }

        do {
            try tunnel.tunnelProvider.sendProviderMessage(Data([0])) { response in
                guard let data = response, let config = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    applyRuntimeStats(config)
                }
            }
        } catch {
            // Session might not be ready yet
        }
    }

    private func applyRuntimeStats(_ config: String) {
        let stats = StatsFormatter.parse(config)
        rxBytes = StatsFormatter.formatBytes(stats.rxBytes)
        txBytes = StatsFormatter.formatBytes(stats.txBytes)

        if stats.lastHandshakeTimestamp > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(stats.lastHandshakeTimestamp))
            let elapsed = Date().timeIntervalSince(date)
            lastHandshake = StatsFormatter.formatTimeAgo(elapsed, loc: loc)
        } else {
            lastHandshake = "—"
        }
    }

}
