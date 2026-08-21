import SwiftUI

struct TunnelStatusRow: View {
    var tunnel: TunnelContainer
    let isGhost: Bool
    var title: String?
    let toggleAXID: String
    let errorAXID: String
    var badgeAXID: String = ""
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        let color = tunnel.status.color
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.12))
                    .frame(width: 36, height: 36)
                if isGhost {
                    GhostGlyph()
                        .fill(color, style: FillStyle(eoFill: true))
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: tunnel.status.iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(color)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(tunnel.status.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(color)
                } else {
                    HStack(spacing: 6) {
                        Text(tunnel.status.localizedDescription)
                            .font(.body.weight(.medium))
                            .foregroundStyle(color)
                        modeBadge
                    }
                }
                if tunnel.stopIsWaitingOnItsRule {
                    Text(loc.t("detail_stopping_disarm"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AXID.TunnelDetail.stoppingDisarm)
                }
                if let error = tunnel.lastActivationError {
                    Text(error.alertText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(errorAXID)
                }
            }

            Spacer()

            Toggle("", isOn: tunnel.toggleBinding(manager: tunnelsManager))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityIdentifier(toggleAXID)
        }
    }

    private var modeBadge: some View {
        Text(isGhost ? "Ghost" : "WireGuard")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(isGhost ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15))
            )
            .foregroundStyle(isGhost ? .purple : .blue)
            .accessibilityIdentifier(badgeAXID)
    }
}

struct StatusSection: View {
    var tunnel: TunnelContainer
    let isGhost: Bool

    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            TunnelStatusRow(
                tunnel: tunnel,
                isGhost: isGhost,
                toggleAXID: AXID.TunnelDetail.statusToggle,
                errorAXID: AXID.TunnelDetail.activationError,
                badgeAXID: AXID.TunnelDetail.modeBadge
            )
        } footer: {
            Text(loc.t("detail_settings_toggle_note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AXID.TunnelDetail.settingsToggleNote)
        }
    }
}

// MARK: - Previews

#Preview {
    let manager = PreviewFixtures.tunnelsManager()
    manager.tunnels[1].lastActivationError = PreviewFixtures.activationError
    return Form {
        StatusSection(tunnel: manager.tunnels[0], isGhost: true)
        StatusSection(tunnel: manager.tunnels[1], isGhost: false)
    }
    .formStyle(.grouped)
    .previewEnvironment(tunnels: manager)
    .frame(width: 560)
}

#Preview("Failing activation — live") {
    let provider = PreviewFixtures.provider(config: PreviewFixtures.ghostConfig(name: "Broken Edge"))
    provider.disconnectError = NSError(
        domain: "PhantomTunnel",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "The wstunnel proxy could not be started."]
    )
    let manager = PreviewFixtures.tunnelsManager(providers: [provider])
    return Form {
        StatusSection(tunnel: manager.tunnels[0], isGhost: true)
    }
    .formStyle(.grouped)
    .previewEnvironment(tunnels: manager)
    .frame(width: 560)
}
