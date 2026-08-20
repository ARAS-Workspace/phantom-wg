import SwiftUI

/// Entry point into the full-screen log view. Shows a live entry count
/// badge so the operator knows the extension is emitting telemetry
/// without having to open the log view.
struct LogNavigationSection: View {
    var logStore: LogStore
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
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
            .accessibilityIdentifier(AXID.TunnelDetail.logsLink)
        }
    }
}

// MARK: - Previews

#Preview {
    let store = LogStore(tunnel: nil)
    store.entries = PreviewFixtures.logEntries
    return NavigationStack {
        Form {
            LogNavigationSection(logStore: store)
        }
        .formStyle(.grouped)
    }
    .previewEnvironment()
    .frame(width: 560)
}
