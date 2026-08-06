import SwiftUI

/// Activate-on-demand toggle — when on, the system starts the tunnel
/// whenever a network connection is available and keeps it up, with
/// the app closed and across device restarts included. The binding is
/// supplied by the parent so the side-effect (save preferences, apply
/// on-demand rules) lives with the tunnel orchestration.
struct OnDemandSection: View {
    @Binding var onDemandEnabled: Bool
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            Toggle(isOn: $onDemandEnabled) {
                Label(loc.t("detail_on_demand"), systemImage: "bolt.shield")
            }
            .accessibilityIdentifier(AXID.TunnelDetail.onDemandToggle)
        } footer: {
            Text(loc.t("detail_on_demand_footer"))
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    PreviewBindingHost(true) { enabled in
        Form {
            OnDemandSection(onDemandEnabled: enabled)
        }
        .formStyle(.grouped)
    }
    .previewEnvironment(scheme: .light)
}

#Preview("Dark") {
    PreviewBindingHost(true) { enabled in
        Form {
            OnDemandSection(onDemandEnabled: enabled)
        }
        .formStyle(.grouped)
    }
    .previewEnvironment(scheme: .dark)
}
