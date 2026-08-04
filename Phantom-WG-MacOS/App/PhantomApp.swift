import SwiftUI
import AppKit

@main
@MainActor
struct PhantomApp: App {

    @State private var coordinator: ExtensionGateCoordinator
    @State private var sessionCoordinator: SplitTunnelingSessionCoordinator
    @State private var tunnelsManager: TunnelsManagerLoader
    @State private var loc: LocalizationManager
    @State private var splitTunnelingStore: SplitTunnelingStore
    @State private var splitProviderManager: SplitTunnelProviderManager
    @State private var dnsProviderManager: DNSProxyProviderManager
    @State private var dnsDaemonClient: DNSProxyDaemonClient
    @State private var splitDaemonClient: SplitTunnelDaemonClient
    @State private var interfaceResolver: PhysicalInterfaceResolver
    @State private var toastCenter: ToastCenter
    @State private var vaultClient: TunnelVaultClient
    @State private var vaultSession: TunnelVaultSession

    init() {
        let loc = LocalizationManager.shared
        let coordinator = ExtensionGateCoordinator()
        let tunnelsManager = TunnelsManagerLoader()
        let splitTunnelingStore = SplitTunnelingStore()
        let splitProviderManager = SplitTunnelProviderManager()
        let dnsProviderManager = DNSProxyProviderManager()
        let dnsDaemonClient = DNSProxyDaemonClient()
        let splitDaemonClient = SplitTunnelDaemonClient()
        let sessionCoordinator = SplitTunnelingSessionCoordinator(
            split: splitProviderManager,
            dns: dnsProviderManager,
            dnsDaemonClient: dnsDaemonClient,
            splitDaemonClient: splitDaemonClient
        )
        splitTunnelingStore.sessionCoordinator = sessionCoordinator

        _loc = State(initialValue: loc)
        _coordinator = State(initialValue: coordinator)
        _sessionCoordinator = State(initialValue: sessionCoordinator)
        _tunnelsManager = State(initialValue: tunnelsManager)
        _splitTunnelingStore = State(initialValue: splitTunnelingStore)
        _splitProviderManager = State(initialValue: splitProviderManager)
        _dnsProviderManager = State(initialValue: dnsProviderManager)
        _interfaceResolver = State(initialValue: PhysicalInterfaceResolver())
        let vaultClient = TunnelVaultClient()
        _toastCenter = State(initialValue: ToastCenter())
        _vaultClient = State(initialValue: vaultClient)
        _vaultSession = State(initialValue: TunnelVaultSession(vault: vaultClient))
        _dnsDaemonClient = State(initialValue: dnsDaemonClient)
        _splitDaemonClient = State(initialValue: splitDaemonClient)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if coordinator.allReady {
                    // Second lock: PhantomTunnel and TunnelVault exist
                    // together or not at all — no session, no list.
                    if vaultSession.state == .ready {
                        TunnelContentView(loader: tunnelsManager)
                    } else {
                        TunnelVaultGateView()
                    }
                } else {
                    ExtensionGateView()
                }
            }
            .environment(loc)
            .environment(coordinator)
            .environment(sessionCoordinator)
            .environment(splitTunnelingStore)
            .environment(splitProviderManager)
            .environment(dnsProviderManager)
            .environment(dnsDaemonClient)
            .environment(splitDaemonClient)
            .environment(interfaceResolver)
            .environment(toastCenter)
            .environment(vaultClient)
            .environment(vaultSession)
            .tint(Color.accentColor)
            // Fixed: the layout is designed at this size. Wide enough
            // that a 44-character base64 key sits on one line with
            // room to spare — the configuration screens are dense
            // with monospaced values.
            .frame(width: 560, height: 720)
            .onAppear {
                interfaceResolver.start()
                coordinator.start()
            }
            .onChange(of: coordinator.allReady) { _, ready in
                // A gate that drops voids the session proof: a
                // reinstalled extension is a cold one, and the next
                // entry must probe again rather than trust a stale
                // `.ready`.
                if !ready { vaultSession.invalidate() }
            }
            .task(id: coordinator.allReady) {
                // Boot reconcile once the gate clears. The session
                // coordinator reads the live extension state (NE
                // session can survive across app close/reopen and
                // system reboots) and adopts it as the initial
                // coordinator state. Honors persisted intent
                // (`config.isEnabled`) only when no live session
                // is found — the UI must always mirror what the
                // extensions are actually doing, not a separate
                // persisted bool.
                guard coordinator.allReady else { return }
                await sessionCoordinator.boot(with: splitTunnelingStore.configuration)
            }
        }
        .windowResizability(.contentSize)
    }
}
