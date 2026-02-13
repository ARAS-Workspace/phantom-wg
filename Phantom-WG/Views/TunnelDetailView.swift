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

    private var hasChanges: Bool { editConfig != originalConfig }
    private var isActive: Bool { tunnel.status != .inactive }

    init(tunnel: TunnelContainer) {
        self.tunnel = tunnel
        _logStore = StateObject(wrappedValue: LogStore(tunnelId: tunnel.tunnelConfig?.id.uuidString))
    }

    var body: some View {
        List {
            statusSection
            if isActive { statsSection }
            onDemandSection
            nameSection
            wstunnelSection
            interfaceSection
            peerSection
            logSection
            actionsSection
        }
        .navigationTitle(editConfig.name.isEmpty ? loc.t("detail_tunnel") : editConfig.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hasChanges && !isActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("save")) { saveConfig() }
                        .fontWeight(.semibold)
                }
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
                        .fill(statusBadgeColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: statusBadgeIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(statusBadgeColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(tunnel.status.localizedDescription)
                        .font(.body.weight(.medium))
                        .foregroundStyle(statusTextColor)
                    if let error = tunnel.lastActivationError {
                        Text(error.alertText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                Toggle("", isOn: tunnelBinding)
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

    private var onDemandSection: some View {
        Section {
            Toggle(isOn: onDemandBinding) {
                Label(loc.t("detail_on_demand"), systemImage: "bolt.shield")
            }
        } footer: {
            Text(loc.t("detail_on_demand_footer"))
        }
    }

    private var nameSection: some View {
        Section {
            textField(loc.t("detail_name"), text: $editConfig.name)
        } header: {
            Label(loc.t("detail_general"), systemImage: "gearshape")
        }
    }

    private var wstunnelSection: some View {
        Section {
            textField(loc.t("detail_server_url"), text: $editConfig.wstunnel.url)
            textField(loc.t("detail_secret"), text: $editConfig.wstunnel.secret)
            portField(loc.t("detail_local_port"), value: $editConfig.wstunnel.localPort)
            textField(loc.t("detail_remote_host"), text: $editConfig.wstunnel.remoteHost)
            portField(loc.t("detail_remote_port"), value: $editConfig.wstunnel.remotePort)
        } header: {
            Label(loc.t("detail_wstunnel"), systemImage: "network.badge.shield.half.filled")
        }
    }

    private var interfaceSection: some View {
        Section {
            textField(loc.t("detail_private_key"), text: $editConfig.interface.privateKey)
            textField(loc.t("detail_address"), text: $editConfig.interface.address)
            textField(loc.t("detail_dns"), text: $editConfig.interface.dns)
            intField(loc.t("detail_mtu"), value: $editConfig.interface.mtu)
        } header: {
            Label(loc.t("detail_interface"), systemImage: "rectangle.connected.to.line.below")
        }
    }

    private var peerSection: some View {
        Section {
            textField(loc.t("detail_public_key"), text: $editConfig.peer.publicKey)
            textField(loc.t("detail_preshared_key"), text: presharedKeyBinding)
            textField(loc.t("detail_allowed_ips"), text: $editConfig.peer.allowedIPs)
            textField(loc.t("detail_endpoint"), text: $editConfig.peer.endpoint)
            intField(loc.t("detail_keepalive"), value: $editConfig.peer.persistentKeepalive)
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
                                .fill(Color(.systemGray5))
                        )
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            copyButton(loc.t("detail_copy_json"), icon: "curlybraces", id: "json") { copyJSON() }
            copyButton(loc.t("detail_copy_logs"), icon: "text.quote", id: "logs") { copyLogs() }

            Button {
                logStore.clear()
            } label: {
                Label(loc.t("detail_clear_logs"), systemImage: "trash.circle")
            }

            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label(loc.t("detail_delete_tunnel"), systemImage: "trash")
            }
            .disabled(isActive)
        } header: {
            Label(loc.t("detail_actions"), systemImage: "ellipsis.circle")
        }
    }

    // MARK: - Field Builders

    private func textField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(isActive)
                .foregroundStyle(isActive ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }

    private func portField(_ label: String, value: Binding<UInt16>) -> some View {
        let stringBinding = Binding<String>(
            get: { "\(value.wrappedValue)" },
            set: { if let v = UInt16($0) { value.wrappedValue = v } }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(label, text: stringBinding)
                .font(.system(.body, design: .monospaced))
                .keyboardType(.numberPad)
                .disabled(isActive)
                .foregroundStyle(isActive ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }

    private func intField(_ label: String, value: Binding<Int>) -> some View {
        let stringBinding = Binding<String>(
            get: { "\(value.wrappedValue)" },
            set: { if let v = Int($0) { value.wrappedValue = v } }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(label, text: stringBinding)
                .font(.system(.body, design: .monospaced))
                .keyboardType(.numberPad)
                .disabled(isActive)
                .foregroundStyle(isActive ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }

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

    private var tunnelBinding: Binding<Bool> {
        Binding(
            get: {
                tunnel.status == .active || tunnel.status == .activating ||
                tunnel.status == .waiting || tunnel.status == .reasserting ||
                tunnel.status == .restarting
            },
            set: { isOn in
                if isOn { tunnelsManager.startActivation(of: tunnel) } else { tunnelsManager.startDeactivation(of: tunnel) }
            }
        )
    }

    private var onDemandBinding: Binding<Bool> {
        Binding(
            get: { tunnel.isActivateOnDemandEnabled },
            set: { isOn in
                let option: ActivateOnDemandOption = isOn ? .wifiOrCellular : .off
                let provider = tunnel.tunnelProvider
                option.apply(on: provider)
                Task {
                    try? await provider.savePreferences()
                    try? await provider.loadPreferences()
                }
            }
        )
    }

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
                try await tunnelsManager.modify(tunnel: tunnel, with: editConfig,
                                                onDemand: tunnel.activateOnDemandSetting)
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
        UIPasteboard.general.string = json
    }

    private func copyLogs() {
        let text = logStore.entries.map { $0.text }.joined(separator: "\n")
        UIPasteboard.general.string = text.isEmpty ? loc.t("detail_no_logs") : text
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
