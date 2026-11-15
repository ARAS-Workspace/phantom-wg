import SwiftUI

struct TunnelListRow: View {
    let tunnel: TunnelContainer

    var body: some View {
        NavigationLink(destination: TunnelDetailView(tunnel: tunnel)) {
            HStack(spacing: 6) {
                TunnelRow(tunnel: tunnel)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .controlSize(.mini)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: TunnelListRules.rowHeight)
    }
}

// MARK: - Previews

#Preview("Row") {
    let manager = PreviewFixtures.tunnelsManager()
    return NavigationStack {
        TunnelListRow(tunnel: manager.tunnels[0])
            .groupedCard()
            .padding(20)
    }
    .previewEnvironment(tunnels: manager)
    .frame(width: WindowSizing.ideal.width)
}
