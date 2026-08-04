import SwiftUI

/// Placeholder shown when no tunnels have been imported yet. Presents
/// the brand logo faded, a short explanation, the primary import call
/// to action, and secondary links to the website and documentation.
struct EmptyStateView: View {
    @Binding var showingImport: Bool
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("PhantomLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .opacity(0.35)

            VStack(spacing: 8) {
                Text(loc.t("tunnel_list_empty_title"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(loc.t("tunnel_list_empty_description"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showingImport = true
            } label: {
                Label(loc.t("import_title"), systemImage: "plus.circle.fill")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier(AXID.TunnelList.emptyImportButton)

            Spacer()

            HStack(spacing: 24) {
                Link(destination: URL(string: "https://www.phantom.tc")!) {
                    Label(loc.t("website"), systemImage: "globe")
                        .font(.footnote)
                }
                Link(destination: URL(string: "https://www.phantom.tc/docs")!) {
                    Label(loc.t("documentation"), systemImage: "book")
                        .font(.footnote)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 20)
        }
        .padding()
    }
}

// MARK: - Previews

#Preview("Light") {
    PreviewBindingHost(false) { showingImport in
        EmptyStateView(showingImport: showingImport)
    }
    .previewEnvironment(scheme: .light)
    .frame(width: 560, height: 720)
}

#Preview("Dark") {
    PreviewBindingHost(false) { showingImport in
        EmptyStateView(showingImport: showingImport)
    }
    .previewEnvironment(scheme: .dark)
    .frame(width: 560, height: 720)
}
