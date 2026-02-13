import SwiftUI

struct LogView: View {
    @ObservedObject var logStore: LogStore
    @EnvironmentObject var loc: LocalizationManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(logStore.entries) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.tag)
                                .font(.system(.caption2, design: .monospaced))
                                .fontWeight(.bold)
                                .foregroundStyle(tagColor(entry.tag))
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
        .overlay {
            if logStore.entries.isEmpty {
                ContentUnavailableView(
                    loc.t("detail_no_logs"),
                    systemImage: "text.justify.left",
                    description: Text(loc.t("log_empty_description"))
                )
            }
        }
    }

    private func tagColor(_ tag: String) -> Color {
        switch tag {
        case "WS": return .orange
        case "WG": return .green
        case "TUN": return .blue
        default: return .secondary
        }
    }
}
