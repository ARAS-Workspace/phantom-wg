import SwiftUI

/// Headerless top block mirroring the running tunnel: the same
/// status row the detail view renders, surfaced so connection state
/// and the master toggle are reachable without opening the detail.
///
/// Deliberately not a titled section — its position above the titled
/// tunnel list already says what it is. (The title was originally
/// dropped as a workaround: a header in a `List`'s first slot left
/// intermittent phantom spacing after navigation pops. The screen
/// has since moved to `Form`, which never showed the band, so the
/// omission survives as a design choice, not a necessity.)
/// While every tunnel is inactive a quiet placeholder keeps the block
/// stable. Only appears once at least one tunnel exists — the empty
/// state stays untouched.
struct ActiveTunnelSection: View {
    let activeTunnel: TunnelContainer?
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            if let tunnel = activeTunnel {
                TunnelStatusRow(
                    tunnel: tunnel,
                    isGhost: tunnel.isGhost,
                    title: tunnel.name,
                    toggleAXID: AXID.TunnelList.activeToggle,
                    errorAXID: AXID.TunnelList.activeError
                )
                .padding(.bottom, 8)
            } else {
                noActiveRow
                    .padding(.bottom, 8)
            }
        }
    }

    private var noActiveRow: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "shield.slash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text(loc.t("tunnel_list_no_active"))
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .accessibilityIdentifier(AXID.TunnelList.activeNone)
    }
}

// MARK: - Previews

#Preview("Active ghost") {
    let manager = PreviewFixtures.tunnelsManager()
    return Form {
        ActiveTunnelSection(activeTunnel: manager.tunnels[0])
    }
    .formStyle(.grouped)
    .previewEnvironment(tunnels: manager)
    .frame(width: 560)
}

#Preview("None active") {
    Form {
        ActiveTunnelSection(activeTunnel: nil)
    }
    .formStyle(.grouped)
    .previewEnvironment()
    .frame(width: 560)
}
