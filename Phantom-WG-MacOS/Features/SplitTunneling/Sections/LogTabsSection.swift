import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum LogChannel {
    case split
    case dns
}

struct LogTabsSection: View {
    let splitLogStore: ProxyLogStore
    let dnsLogStore: ProxyLogStore
    @Environment(LocalizationManager.self) private var loc

    @State private var channel: LogChannel = .split
    @State private var savingError: String?
    @State private var showingSaveError = false

    var body: some View {
        Section {
            VStack(spacing: 8) {
                tabPicker
                toolbar
                scrollPanel
            }
        } header: {
            Label(loc.t("detail_logs"), systemImage: "text.justify.left")
                .padding(.leading, 4)
        }
        .alert(loc.t("error"), isPresented: $showingSaveError) {
            Button(loc.t("ok")) {}
        } message: {
            Text(savingError ?? "")
        }
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        Picker("", selection: $channel) {
            Text(loc.t("logs_tab_split_tunnel"))
                .tag(LogChannel.split)
                .accessibilityIdentifier(AXID.SplitTunneling.logsTabSplit)
            Text(loc.t("logs_tab_dns_proxy"))
                .tag(LogChannel.dns)
                .accessibilityIdentifier(AXID.SplitTunneling.logsTabDns)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier(AXID.SplitTunneling.logsTab)
    }

    // MARK: - Active Channel Accessors

    private var entries: [LogEntry] {
        switch channel {
        case .split: return splitLogStore.entries
        case .dns:   return dnsLogStore.entries
        }
    }

    private func clearActive() async {
        switch channel {
        case .split: await splitLogStore.clear()
        case .dns:   await dnsLogStore.clear()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(entryCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.12))
                )
                .accessibilityIdentifier(AXID.SplitTunneling.logsCount)

            Spacer(minLength: 0)

            Button {
                saveLog()
            } label: {
                Label(loc.t("log_save"), systemImage: "square.and.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(loc.t("log_save"))
            .disabled(entries.isEmpty)
            .accessibilityIdentifier(AXID.SplitTunneling.logsSave)

            Button {
                Task { await clearActive() }
            } label: {
                Label(loc.t("log_clear"), systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(loc.t("log_clear"))
            .disabled(entries.isEmpty)
            .accessibilityIdentifier(AXID.SplitTunneling.logsClear)
        }
    }

    private var entryCountLabel: String {
        let count = entries.count
        return String(format: loc.t("log_entry_count"), count)
    }

    // MARK: - Scroll Panel

    private var scrollPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if entries.isEmpty {
                        Text(loc.t("split_tunneling_log_empty"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(entries) { entry in
                            entryRow(entry)
                                .id(entry.id)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 240)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: entries.count) { _, _ in
                if let last = entries.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: channel) { _, _ in
                if let last = entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func entryRow(_ entry: LogEntry) -> some View {
        Text(entry.text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .lineLimit(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
    }

    // MARK: - Save

    private func saveLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .log]
        panel.nameFieldStringValue = defaultFilename()
        panel.canCreateDirectories = true
        panel.title = loc.t("log_save")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let contents = entries.map(\.text).joined(separator: "\n") + "\n"

        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            savingError = error.localizedDescription
            showingSaveError = true
        }
    }

    private func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stem = channel == .split ? "split" : "dns"
        return "phantom-\(stem)-log-\(formatter.string(from: Date())).txt"
    }
}

// MARK: - Previews

private struct LogTabsPreviewHost: View {
    private let splitClient = SplitTunnelDaemonClient()
    private let dnsClient = DNSProxyDaemonClient()
    private let splitStore: ProxyLogStore
    private let dnsStore: ProxyLogStore

    init() {
        splitStore = ProxyLogStore(daemonClient: splitClient, tag: "SPL")
        splitStore.entries = [
            LogEntry(id: 0, tag: "SPL", text: "[12:04:12] flow com.apple.Safari → en0 (bypass)"),
            LogEntry(id: 1, tag: "SPL", text: "[12:04:13] flow org.videolan.vlc → en0 (bypass)"),
            LogEntry(id: 2, tag: "SPL", text: "[12:04:15] flow com.example.app → default route")
        ]
        dnsStore = ProxyLogStore(daemonClient: dnsClient, tag: "DNS")
        dnsStore.entries = [
            LogEntry(id: 0, tag: "DNS", text: "[12:04:12] query safari.apple.com A via en0"),
            LogEntry(id: 1, tag: "DNS", text: "[12:04:14] query update.vlc.org AAAA via en0")
        ]
    }

    var body: some View {
        Form {
            LogTabsSection(splitLogStore: splitStore, dnsLogStore: dnsStore)
        }
        .formStyle(.grouped)
    }
}

#Preview("Light") {
    LogTabsPreviewHost()
        .previewEnvironment(scheme: .light)
        .frame(width: 560, height: 480)
}

#Preview("Dark") {
    LogTabsPreviewHost()
        .previewEnvironment(scheme: .dark)
        .frame(width: 560, height: 480)
}
