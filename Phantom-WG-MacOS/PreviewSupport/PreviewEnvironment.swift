import SwiftUI

extension View {

    /// Preview-grade mirror of `PhantomApp`'s composition root: builds
    /// the same object graph with `PreviewFixtures` instances and
    /// injects the full environment stack in one call, so every
    /// `#Preview` reads like `SomeView().previewEnvironment()`.
    ///
    /// One deliberate difference from production: `TunnelsManager` is
    /// injected here as well. The app injects it a level deeper
    /// (`TunnelContentView` → `TunnelListView`) only because it loads
    /// asynchronously; previews start with it ready.
    @MainActor
    func previewEnvironment(
        tunnels: TunnelsManager? = nil,
        gate: ExtensionGateCoordinator? = nil,
        splitStore: SplitTunnelingStore? = nil,
        vaultSession: TunnelVaultSession? = nil,
        sessionState: SplitTunnelingSessionCoordinator.State = .stopped,
        scheme: ColorScheme? = nil
    ) -> some View {
        let manager = tunnels ?? PreviewFixtures.tunnelsManager()
        let coordinator = gate ?? PreviewFixtures.gateCoordinator()
        let store = splitStore ?? PreviewFixtures.splitStore()
        let session = vaultSession ?? PreviewFixtures.vaultSession()
        let sessionCoordinator = PreviewFixtures.sessionCoordinator(state: sessionState)
        store.sessionCoordinator = sessionCoordinator

        return self
            .environment(LocalizationManager.shared)
            .environment(coordinator)
            .environment(sessionCoordinator)
            .environment(manager)
            .environment(manager.vault)
            .environment(session)
            .environment(store)
            .environment(SplitTunnelProviderManager())
            .environment(DNSProxyProviderManager())
            .environment(DNSProxyDaemonClient())
            .environment(SplitTunnelDaemonClient())
            .environment(PhysicalInterfaceResolver())
            .environment(ToastCenter())
            .tint(Color.accentColor)
            // `nil` follows the system appearance — pass a scheme only
            // in the paired Light/Dark preview variants.
            .preferredColorScheme(scheme)
    }
}

/// Generic `@State` host so previews can hand a real, interactive
/// `Binding` to views that require one — no per-preview host structs.
struct PreviewBindingHost<Value, Content: View>: View {

    @State private var value: Value
    private let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.content = content
    }

    var body: some View {
        content($value)
    }
}
