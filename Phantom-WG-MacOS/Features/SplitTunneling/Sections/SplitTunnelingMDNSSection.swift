import SwiftUI

struct SplitTunnelingMDNSSection: View {
    @Binding var isEnabled: Bool
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            Toggle(loc.t("mdns_toggle_label"), isOn: $isEnabled)
                .accessibilityIdentifier(AXID.SplitTunneling.mdnsToggle)
            Text(loc.t("mdns_toggle_description"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Label(loc.t("mdns_section_title"), systemImage: "network.badge.shield.half.filled")
                .padding(.leading, 4)
        }
    }
}

// MARK: - Previews

#Preview {
    PreviewBindingHost(true) { isEnabled in
        Form {
            SplitTunnelingMDNSSection(isEnabled: isEnabled)
        }
        .formStyle(.grouped)
    }
    .previewEnvironment()
    .frame(width: 560)
}
