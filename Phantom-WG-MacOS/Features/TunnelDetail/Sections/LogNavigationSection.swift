import SwiftUI

struct LogNavigationSection: View {
    var logStore: LogStore
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        CardSection {
            NavigationLink {
                LogView(logStore: logStore)
            } label: {
                HStack {
                    Label(loc.t("detail_logs"), systemImage: "text.justify.left")
                    Spacer()
                    Text("\(logStore.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.15))
                        )
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(TunnelRowPressStyle())
            .accessibilityIdentifier(AXID.TunnelDetail.logsLink)
        }
    }
}

// MARK: - Previews

#Preview {
    let store = LogStore(tunnel: nil)
    store.entries = PreviewFixtures.logEntries
    store.count = store.entries.count
    return NavigationStack {
        VStack(alignment: .leading, spacing: 16) {
            LogNavigationSection(logStore: store)
        }
        .padding(20)
    }
    .previewEnvironment()
    .frame(width: WindowSizing.ideal.width)
}
