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
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: TunnelListRules.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(TunnelRowPressStyle())
        .controlSize(.mini)
    }
}

struct TunnelRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear))
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
