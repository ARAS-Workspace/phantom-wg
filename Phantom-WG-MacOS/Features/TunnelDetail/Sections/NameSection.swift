import SwiftUI

struct NameSection: View {
    let name: String
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        CardSection {
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
    VStack(alignment: .leading, spacing: 16) {
        NameSection(name: "Istanbul Edge")
    }
    .padding(20)
    .previewEnvironment()
    .frame(width: WindowSizing.ideal.width)
}
