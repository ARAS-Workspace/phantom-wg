import SwiftUI

/// Single row in the tunnel list. Left-side status indicator, stacked
/// name/status text, and a trailing master toggle that dispatches
/// activation/deactivation through `TunnelsManager`.
struct TunnelRow: View {
    var tunnel: TunnelContainer
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        HStack(spacing: 12) {
            statusIndicator

            VStack(alignment: .leading, spacing: 3) {
                Text(tunnel.name)
                    .font(.body.weight(.medium))
                Text(tunnel.status.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: tunnel.toggleBinding(manager: tunnelsManager))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityIdentifier(AXID.TunnelList.rowToggle(tunnel.name))
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier(AXID.TunnelList.row(tunnel.name))
    }

    private var statusIndicator: some View {
        let color = tunnel.status.color
        let isGhost = tunnel.isGhost
        return ZStack {
            Circle()
                .fill(color.opacity(0.15))
                .frame(width: 32, height: 32)
            if isGhost {
                GhostGlyph()
                    .fill(color, style: FillStyle(eoFill: true))
                    .frame(width: 15, height: 15)
            } else {
                Image(systemName: tunnel.status.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
    }
}

// MARK: - Previews

#Preview("Row states") {
    let manager = PreviewFixtures.tunnelsManager()
    manager.tunnels[1].status = .activating
    return List {
        ForEach(manager.tunnels) { tunnel in
            TunnelRow(tunnel: tunnel)
        }
    }
    .listStyle(.inset)
    .previewEnvironment(tunnels: manager)
    .frame(width: 560)
}
