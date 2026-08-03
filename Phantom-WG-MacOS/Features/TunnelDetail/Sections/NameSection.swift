import SwiftUI

/// Tunnel display name input. Single editable field with the standard
/// error treatment; becomes read-only while the tunnel is active.
struct NameSection: View {
    @Binding var name: String
    let isEditable: Bool
    let errorMessage: String?
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            PhantomTextField(
                label: loc.t("detail_name"),
                text: $name,
                isDisabled: !isEditable,
                errorMessage: errorMessage,
                axIdentifier: AXID.TunnelDetail.Name.field
            )
        } header: {
            Label(loc.t("detail_general"), systemImage: "gearshape")
        }
    }
}

// MARK: - Previews

#Preview {
    PreviewBindingHost("Istanbul Edge") { name in
        List {
            NameSection(name: name, isEditable: true, errorMessage: nil)
            NameSection(name: name, isEditable: false, errorMessage: nil)
            NameSection(name: name, isEditable: true, errorMessage: "A tunnel with this name already exists.")
        }
    }
    .previewEnvironment()
    .frame(width: 480)
}
