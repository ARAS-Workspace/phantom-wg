import SwiftUI

struct InterfaceUnavailableBanner: View {
    let selectionLabel: String
    let onSwitchToAuto: () -> Void
    let onDisable: () -> Void
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("split_tunneling_interface_unavailable_title"))
                    .font(.callout.weight(.semibold))

                Text(String(
                    format: loc.t("split_tunneling_interface_unavailable_message"),
                    selectionLabel
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(loc.t("split_tunneling_switch_to_auto"), action: onSwitchToAuto)
                        .controlSize(.small)
                    Button(loc.t("split_tunneling_disable_feature"), action: onDisable)
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier(AXID.SplitTunneling.interfaceUnavailableBanner)
    }
}

// MARK: - Previews

#Preview("Light") {
    InterfaceUnavailableBanner(
        selectionLabel: "Ethernet (en5)",
        onSwitchToAuto: {},
        onDisable: {}
    )
    .padding(24)
    .previewEnvironment(scheme: .light)
    .frame(width: 560)
}

#Preview("Dark") {
    InterfaceUnavailableBanner(
        selectionLabel: "Ethernet (en5)",
        onSwitchToAuto: {},
        onDisable: {}
    )
    .padding(24)
    .previewEnvironment(scheme: .dark)
    .frame(width: 560)
}
