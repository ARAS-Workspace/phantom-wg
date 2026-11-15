import SwiftUI

struct ActiveTunnelSection: View {
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(loc.t("active_tunnel_header"), systemImage: "bolt.horizontal.circle")
                .font(.headline)
                .padding(.leading, 10)

            Group {
                if let tunnel = TunnelListRules.slotHolder(in: tunnelsManager.tunnels, status: \.status) {
                    TunnelListRow(tunnel: tunnel)
                } else {
                    emptyState
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: TunnelListRules.rowHeight)
                }
            }
            .groupedCard()
        }
        .accessibilityIdentifier(AXID.TunnelList.activeSection)
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "power")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(loc.t("active_tunnel_empty"))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(loc.t("active_tunnel_empty_hint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AXID.TunnelList.activeEmpty)
    }
}

// MARK: - Previews

#Preview("Active") {
    let manager = PreviewFixtures.tunnelsManager()
    manager.tunnels.forEach { $0.status = .inactive }
    manager.tunnels[0].status = .active
    return ActiveTunnelSection()
        .padding(20)
        .previewEnvironment(tunnels: manager)
        .frame(width: WindowSizing.ideal.width)
}

#Preview("Deactivating, another waiting") {
    let manager = PreviewFixtures.tunnelsManager()
    manager.tunnels.forEach { $0.status = .inactive }
    manager.tunnels[0].status = .deactivating
    manager.tunnels[1].status = .waiting
    return ActiveTunnelSection()
        .padding(20)
        .previewEnvironment(tunnels: manager)
        .frame(width: WindowSizing.ideal.width)
}

#Preview("Empty — Light") {
    ActiveTunnelSection()
        .padding(20)
        .previewEnvironment(tunnels: PreviewFixtures.tunnelsManager(providers: [
            PreviewFixtures.provider(config: PreviewFixtures.wireguardConfig())
        ]), scheme: .light)
        .frame(width: WindowSizing.ideal.width)
}

#Preview("Empty — Dark") {
    ActiveTunnelSection()
        .padding(20)
        .previewEnvironment(tunnels: PreviewFixtures.tunnelsManager(providers: [
            PreviewFixtures.provider(config: PreviewFixtures.wireguardConfig())
        ]), scheme: .dark)
        .frame(width: WindowSizing.ideal.width)
}
