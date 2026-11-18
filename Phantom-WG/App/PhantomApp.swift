import SwiftUI

// ─── TEST MARKERS ────────────────────────────────────────────────────
//
//   /// @witness <Workflow>.<step>
//       The PhantomTestEngine harness (Debug builds only, behind the
//       ladybug button next to the language flag) drives this symbol and
//       asserts on it. `<Workflow>` names a workflow family under
//       `Phantom-WG/PhantomTestEngine/workflows/`; `<step>` names one
//       method in that family. Grep the name to read the assertions. A
//       symbol carrying several markers is exercised from several angles.
//
// The markers are not exhaustive: an unmarked symbol usually has no
// harness witness, but not always.

@main
struct PhantomApp: App {
    @State private var tunnelsManager = TunnelsManagerLoader()
    @State private var loc = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if let manager = tunnelsManager.manager {
                    TunnelListView()
                        .environment(manager)
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
            .environment(loc)
            .tint(Color.accentColor)
            .coveredWhileInactive()
        }
    }

    // Internal, not private: the #Preview blocks below live outside
    // the type and could not reach a private member.
    var loadingView: some View {
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

// MARK: - Previews

#Preview("Loading — Light") {
    PhantomApp().loadingView
        .preferredColorScheme(.light)
}

#Preview("Loading — Dark") {
    PhantomApp().loadingView
        .preferredColorScheme(.dark)
}

/// Faithful stand-in for the system launch screen: `UILaunchScreen`
/// centers `PhantomLogo` at its intrinsic size on the system
/// background — exactly this layout, no scaling anywhere.
#Preview("Launch — Light") {
    ZStack {
        Color(.systemBackground).ignoresSafeArea()
        Image("PhantomLogo")
    }
    .preferredColorScheme(.light)
}

#Preview("Launch — Dark") {
    ZStack {
        Color(.systemBackground).ignoresSafeArea()
        Image("PhantomLogo")
    }
    .preferredColorScheme(.dark)
}
