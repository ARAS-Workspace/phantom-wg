import SwiftUI

struct LogView: View {
    var logStore: any LogEntryProvider
    @State private var copied = false
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(logStore.entries) { entry in
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
                }
                .padding(.vertical, 8)
                .accessibilityIdentifier(AXID.LogView.list)
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: logStore.entries.count) { _, _ in
                if let last = logStore.entries.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle(loc.t("detail_logs"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Copy is the only practical way to get logs off the
            // device, so it lives here next to the entries — on
            // macOS the same lines are selectable text on screen.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = logStore.entries
                        .map { $0.text }
                        .joined(separator: "\n")
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(loc.t("log_copy"),
                          systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                }
                .disabled(logStore.entries.isEmpty)
                .accessibilityIdentifier(AXID.LogView.copyButton)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await logStore.clear() }
                } label: {
                    Label(loc.t("log_clear"), systemImage: "trash")
                }
                .disabled(logStore.entries.isEmpty)
                .accessibilityIdentifier(AXID.LogView.clearButton)
            }
        }
        .overlay {
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
    }

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

#Preview("Streaming — Light") {
    let store = LogStore(tunnel: nil)
    store.entries = PreviewFixtures.logEntries
    return NavigationStack {
        LogView(logStore: store)
    }
    .previewEnvironment(scheme: .light)
}

#Preview("Streaming — Dark") {
    let store = LogStore(tunnel: nil)
    store.entries = PreviewFixtures.logEntries
    return NavigationStack {
        LogView(logStore: store)
    }
    .previewEnvironment(scheme: .dark)
}

#Preview("Empty") {
    NavigationStack {
        LogView(logStore: LogStore(tunnel: nil))
    }
    .previewEnvironment()
}
