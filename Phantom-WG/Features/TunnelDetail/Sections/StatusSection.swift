import SwiftUI

/// Shared status row — indicator, localized status text, and the
/// master activation toggle. Rendered by the detail's status section
/// and mirrored at the top of the tunnel list for the active tunnel.
/// A non-nil `title` puts the tunnel name above the status line and
/// hides the mode badge — the list mirror needs the name as meta and
/// the ghost/standalone signal comes from the indicator icon there;
/// the detail keeps the badge and carries the name in its navigation
/// title. Ghost tunnels show the brand ghost glyph instead of the
/// shield status icon. Accessibility identifiers are caller-supplied
/// so the two surfaces stay individually addressable when both are
/// in the hierarchy.
struct TunnelStatusRow: View {
    var tunnel: TunnelContainer
    let isGhost: Bool
    var title: String?
    let toggleAXID: String
    let errorAXID: String
    var badgeAXID: String = ""
    @Environment(TunnelsManager.self) private var tunnelsManager

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
                if let error = tunnel.lastActivationError {
                    Text(error.alertText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(errorAXID)
                }
            }

            Spacer()

            Toggle("", isOn: tunnel.toggleBinding(manager: tunnelsManager))
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

/// Top block of the tunnel detail view — the shared status row.
/// Headerless to match the macOS presentation: it is the status
/// summary, sitting directly under the navigation title, and needs
/// no caption.
struct StatusSection: View {
    var tunnel: TunnelContainer
    let isGhost: Bool

    var body: some View {
        Section {
            TunnelStatusRow(
                tunnel: tunnel,
                isGhost: isGhost,
                toggleAXID: AXID.TunnelDetail.statusToggle,
                errorAXID: AXID.TunnelDetail.activationError,
                badgeAXID: AXID.TunnelDetail.modeBadge
            )
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    let manager = PreviewFixtures.tunnelsManager()
    manager.tunnels[1].lastActivationError = PreviewFixtures.activationError
    return Form {
        StatusSection(tunnel: manager.tunnels[0], isGhost: true)
        StatusSection(tunnel: manager.tunnels[1], isGhost: false)
    }
    .formStyle(.grouped)
    .previewEnvironment(tunnels: manager, scheme: .light)
}

#Preview("Dark") {
    let manager = PreviewFixtures.tunnelsManager()
    manager.tunnels[1].lastActivationError = PreviewFixtures.activationError
    return Form {
        StatusSection(tunnel: manager.tunnels[0], isGhost: true)
        StatusSection(tunnel: manager.tunnels[1], isGhost: false)
    }
    .formStyle(.grouped)
    .previewEnvironment(tunnels: manager, scheme: .dark)
}

/// Live twin of the real-disconnect flow: flip the toggle and the
/// session drops after a beat, surfacing the provider's own record
/// through the same fetch path production uses. The sample mirrors
/// `PacketTunnelProviderError.couldNotStartWstunnel` — a listener
/// that fails to open is a real start-time throw; an unreachable
/// server is not (wstunnel connects lazily and never fails start).
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
}
