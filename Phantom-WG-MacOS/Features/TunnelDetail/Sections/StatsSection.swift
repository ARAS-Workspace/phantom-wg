import SwiftUI

/// Live traffic stats polled from the extension — last handshake time,
/// bytes received, bytes sent. Values are formatted strings owned by
/// the parent view so polling state stays in one place.
struct StatsSection: View {
    let handshake: String
    let rxBytes: String
    let txBytes: String
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            StatRow(icon: "hand.wave", label: loc.t("detail_handshake"), value: handshake)
                .accessibilityIdentifier(AXID.TunnelDetail.Stats.handshake)
            StatRow(icon: "arrow.down.circle", label: loc.t("detail_received"), value: rxBytes, valueColor: .green)
                .accessibilityIdentifier(AXID.TunnelDetail.Stats.rxBytes)
            StatRow(icon: "arrow.up.circle", label: loc.t("detail_sent"), value: txBytes, valueColor: .blue)
                .accessibilityIdentifier(AXID.TunnelDetail.Stats.txBytes)
        } header: {
            Label(loc.t("detail_transfer"), systemImage: "chart.bar.fill")
        }
    }
}

// MARK: - Previews

#Preview("Live values") {
    List {
        StatsSection(handshake: "12 seconds ago", rxBytes: "45.12 MB", txBytes: "8.79 MB")
    }
    .previewEnvironment()
    .frame(width: 480)
}

#Preview("Idle") {
    List {
        StatsSection(handshake: "—", rxBytes: "—", txBytes: "—")
    }
    .previewEnvironment()
    .frame(width: 480)
}
