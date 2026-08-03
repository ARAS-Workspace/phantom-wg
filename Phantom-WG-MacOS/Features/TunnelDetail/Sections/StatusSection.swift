import SwiftUI

/// Top section of the tunnel detail view. Shows the status indicator,
/// a mode badge (Ghost vs standalone WireGuard), any activation error,
/// and the master activation toggle.
struct StatusSection: View {
    var tunnel: TunnelContainer
    let isGhost: Bool
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        let color = tunnel.status.color
        Section {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: tunnel.status.iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tunnel.status.localizedDescription)
                            .font(.body.weight(.medium))
                            .foregroundStyle(color)

                        Text(isGhost ? "Ghost" : "WireGuard")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(isGhost ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15))
                            )
                            .foregroundStyle(isGhost ? .purple : .blue)
                            .accessibilityIdentifier(AXID.TunnelDetail.modeBadge)
                    }
                    if let error = tunnel.lastActivationError {
                        Text(error.alertText)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier(AXID.TunnelDetail.activationError)
                    }
                }

                Spacer()

                Toggle("", isOn: tunnel.toggleBinding(manager: tunnelsManager))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityIdentifier(AXID.TunnelDetail.statusToggle)
            }
        } header: {
            Label(loc.t("detail_status"), systemImage: "antenna.radiowaves.left.and.right")
        }
    }
}

// MARK: - Previews

#Preview {
    let manager = PreviewFixtures.tunnelsManager()
    manager.tunnels[1].lastActivationError = PreviewFixtures.activationError
    return List {
        StatusSection(tunnel: manager.tunnels[0], isGhost: true)
        StatusSection(tunnel: manager.tunnels[1], isGhost: false)
    }
    .previewEnvironment(tunnels: manager)
    .frame(width: 480)
}
