import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LogView: View {
    var logStore: any LogEntryProvider
    @Environment(LocalizationManager.self) private var loc

    @State private var savingError: String?
    @State private var showingSaveError = false

    var body: some View {
        scrollContent
            .navigationTitle(loc.t("detail_logs"))
            .toolbar { toolbarContent }
            .overlay { emptyOverlay }
            .onAppear { logStore.startPolling() }
            .onDisappear { logStore.stopPolling() }
            .alert(loc.t("error"), isPresented: $showingSaveError) {
                Button(loc.t("ok")) {}
                    .accessibilityIdentifier(AXID.LogView.saveErrorOK)
            } message: {
                Text(savingError ?? "")
            }
    }

    private var scrollContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(logStore.entries) { entry in
                        entryRow(entry)
                    }
                }
                .padding(.vertical, 8)
                .accessibilityIdentifier(AXID.LogView.list)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: logStore.entries.last?.id) { _, lastID in
                guard let lastID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private func entryRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.tag)
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(colorForTag(entry.tag))
                .frame(width: 28, alignment: .leading)

            Text(entry.text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .id(entry.id)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                saveLog()
            } label: {
                Label(loc.t("log_save"), systemImage: "square.and.arrow.down")
            }
            .disabled(logStore.entries.isEmpty)
            .accessibilityIdentifier(AXID.LogView.saveButton)

            Button {
                Task { await logStore.clear() }
            } label: {
                Label(loc.t("log_clear"), systemImage: "trash")
            }
            .disabled(logStore.entries.isEmpty)
            .accessibilityIdentifier(AXID.LogView.clearButton)
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if logStore.entries.isEmpty {
            ContentUnavailableView(
                loc.t("detail_no_logs"),
                systemImage: "text.justify.left",
                description: Text(loc.t("log_empty_description"))
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AXID.LogView.emptyState)
        }
    }

    // MARK: - Save

    private func saveLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .log]
        panel.nameFieldStringValue = defaultFilename()
        panel.canCreateDirectories = true
        panel.title = loc.t("log_save")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let contents = logStore.entries.map(\.text).joined(separator: "\n") + "\n"

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
        return "phantom-wg-log-\(formatter.string(from: Date())).txt"
    }

    // MARK: - Appearance

    private func colorForTag(_ tag: String) -> Color {
        switch tag {
        case "WS":  return .orange
        case "WG":  return .green
        case "TUN": return .blue
        default:    return .secondary
        }
    }
}

// MARK: - Previews

#Preview("Populated") {
    let store = LogStore(tunnel: nil)
    store.entries = PreviewFixtures.logEntries
    return NavigationStack {
        LogView(logStore: store)
    }
    .previewEnvironment()
    .frame(width: 560, height: 720)
}

#Preview("Empty") {
    NavigationStack {
        LogView(logStore: LogStore(tunnel: nil))
    }
    .previewEnvironment()
    .frame(width: 560, height: 720)
}
