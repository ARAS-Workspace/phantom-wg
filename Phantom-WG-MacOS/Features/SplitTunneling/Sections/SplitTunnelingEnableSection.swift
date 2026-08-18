import SwiftUI

/// Master gate for the whole split tunneling feature. Disabling this
/// parks the interface picker and the app list in read-only state, but
/// preserves the configuration so re-enabling restores it exactly.
///
/// Two corrections to what this said before. The picker and the list
/// no longer follow this toggle's stored value; they follow the
/// SESSION, so they are also parked while a start or a stop is still
/// in flight — an edit made in that window would reach disk and never
/// reach either extension. And the system DNS resolver toggle below
/// them staying live is not because it "is the only section the view
/// builds without an `isDisabled`": the log tabs and the destructive
/// reset take no `isDisabled` either. It stays live as a deliberate
/// choice about that control, not as a consequence of how the view is
/// assembled.
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
