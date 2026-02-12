import SwiftUI

@main
struct PhantomApp: App {
    @StateObject private var tunnelsManager = TunnelsManagerLoader()
    @StateObject private var loc = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if let manager = tunnelsManager.manager {
                    TunnelListView()
                        .environmentObject(manager)
                } else if let error = tunnelsManager.loadError {
                    ContentUnavailableView(
                        loc.t("error"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else {
                    loadingView
                        .task { await tunnelsManager.load() }
                }
            }
            .environmentObject(loc)
            .tint(Color.accentColor)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 20) {
            Image("PhantomLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
            ProgressView(loc.t("app_loading"))
                .tint(.secondary)
        }
    }
}

/// Wrapper to hold TunnelsManager creation state, since TunnelsManager
/// requires async factory and can't be a direct @StateObject.
@MainActor
class TunnelsManagerLoader: ObservableObject {
    @Published var manager: TunnelsManager?
    @Published var loadError: String?

    func load() async {
        do {
            manager = try await TunnelsManager.create()
        } catch {
            loadError = error.localizedDescription
        }
    }
}