import SwiftUI

struct SplitTunnelingEnableSection: View {
    @Binding var isEnabled: Bool
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t("split_tunneling_enable"))
                        .font(.body.weight(.medium))
                    Text(loc.t("split_tunneling_enable_description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier(AXID.SplitTunneling.enableToggle)
        }
    }
}

// MARK: - Previews

#Preview {
    PreviewBindingHost(true) { isEnabled in
        Form {
            SplitTunnelingEnableSection(isEnabled: isEnabled)
        }
        .formStyle(.grouped)
    }
    .previewEnvironment()
    .frame(width: 560)
}
