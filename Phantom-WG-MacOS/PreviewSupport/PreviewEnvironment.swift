import SwiftUI

extension View {

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
            .preferredColorScheme(scheme)
    }
}

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
