import SwiftUI

/// Loading gate between successful system extension activation and
/// the actual tunnel list. Waits for the async preference load on
/// `TunnelsManagerLoader`, surfaces a dedicated error view if the
/// load fails, and otherwise hands control to `TunnelListView` with
/// the live manager in environment.
struct TunnelContentView: View {
    var loader: TunnelsManagerLoader
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Group {
            if let manager = loader.manager {
                TunnelListView()
                    .environment(manager)
            } else if let error = loader.loadError {
                ContentUnavailableView(
                    loc.t("error"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AXID.ExtensionGate.tunnelLoadError)
            } else {
                VStack(spacing: 20) {
                    Image("PhantomLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                    ProgressView(loc.t("app_loading"))
                        .tint(.secondary)
                }
                .task { await loader.load() }
            }
        }
    }
}

// MARK: - Previews

#Preview("Loaded") {
    let manager = PreviewFixtures.tunnelsManager()
    let loader = TunnelsManagerLoader()
    loader.manager = manager
    return TunnelContentView(loader: loader)
        .previewEnvironment(tunnels: manager)
        .frame(width: 480, height: 720)
}

#Preview("Load error") {
    let loader = TunnelsManagerLoader()
    loader.loadError = "The VPN preferences could not be read."
    return TunnelContentView(loader: loader)
        .previewEnvironment()
        .frame(width: 480, height: 720)
}
