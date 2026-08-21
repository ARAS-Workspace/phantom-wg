import SwiftUI

struct TunnelContentView: View {
    var loader: TunnelsManagerLoader
    @Environment(LocalizationManager.self) private var loc
    @Environment(TunnelVaultClient.self) private var vault

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
                    ProgressView {
                        Text(loc.t("app_loading"))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .task { await loader.load(vault: vault) }
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
        .frame(width: 560, height: 720)
}

#Preview("Load error — Light") {
    let loader = TunnelsManagerLoader()
    loader.loadError = "The VPN preferences could not be read."
    return TunnelContentView(loader: loader)
        .previewEnvironment(scheme: .light)
        .frame(width: 560, height: 720)
}

#Preview("Load error — Dark") {
    let loader = TunnelsManagerLoader()
    loader.loadError = "The VPN preferences could not be read."
    return TunnelContentView(loader: loader)
        .previewEnvironment(scheme: .dark)
        .frame(width: 560, height: 720)
}
