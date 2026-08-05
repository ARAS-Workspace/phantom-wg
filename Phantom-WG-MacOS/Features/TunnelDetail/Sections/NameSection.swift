import SwiftUI

/// Tunnel display name, read-only. The name is edited together with
/// the raw configuration in `TunnelEditView`.
struct NameSection: View {
    let name: String
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            PhantomStaticField(
                label: loc.t("detail_name"),
                value: name,
                axIdentifier: AXID.TunnelDetail.Name.field
            )
        } header: {
            Label(loc.t("detail_general"), systemImage: "gearshape")
        }
    }
}

// MARK: - Previews

#Preview {
    Form {
        NameSection(name: "Istanbul Edge")
    }
    .formStyle(.grouped)
    .previewEnvironment()
    .frame(width: 560)
}
