import SwiftUI

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
    Form {
        StatsSection(handshake: "12 seconds ago", rxBytes: "45.12 MB", txBytes: "8.79 MB")
    }
    .formStyle(.grouped)
    .previewEnvironment()
    .frame(width: 560)
}

#Preview("Idle") {
    Form {
        StatsSection(handshake: "—", rxBytes: "—", txBytes: "—")
    }
    .formStyle(.grouped)
    .previewEnvironment()
    .frame(width: 560)
}
