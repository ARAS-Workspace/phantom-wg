import SwiftUI

/// Headerless top block mirroring the running tunnel: the same
/// status row the detail view renders, surfaced so connection state
/// and the master toggle are reachable without opening the detail.
///
/// Deliberately not a titled section — a header in the **first** slot
/// of a `List` intermittently leaves a band of empty space above its
/// own content after a navigation transition (the detail view's
/// status block hit the same thing). Later sections never do, so the
/// house rule is: the first section of a list carries no header. Its
/// position above the titled tunnel list already says what it is.
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
    return List {
        ActiveTunnelSection(activeTunnel: manager.tunnels[0])
    }
    .previewEnvironment(tunnels: manager)
    .frame(width: 560)
}

#Preview("None active") {
    List {
        ActiveTunnelSection(activeTunnel: nil)
    }
    .previewEnvironment()
    .frame(width: 560)
}
