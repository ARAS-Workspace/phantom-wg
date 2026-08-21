import SwiftUI

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
    @State private var connectionGate: ConnectionGateCoordinator

    init() {
        let loc = LocalizationManager.shared
        let tunnelsManager = TunnelsManagerLoader()
        let splitTunnelingStore = SplitTunnelingStore()
        let splitProviderManager = SplitTunnelProviderManager()
        let dnsProviderManager = DNSProxyProviderManager()
        let dnsDaemonClient = DNSProxyDaemonClient()
        let splitDaemonClient = SplitTunnelDaemonClient()
        let vaultClient = TunnelVaultClient()
        let coordinator = ExtensionGateCoordinator(
            vault: vaultClient,
            splitDaemon: splitDaemonClient,
            dnsDaemon: dnsDaemonClient
        )
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
        _toastCenter = State(initialValue: ToastCenter())
        _vaultClient = State(initialValue: vaultClient)
        _vaultSession = State(initialValue: TunnelVaultSession(vault: vaultClient))
        _connectionGate = State(initialValue: ConnectionGateCoordinator(vault: vaultClient))
        _dnsDaemonClient = State(initialValue: dnsDaemonClient)
        _splitDaemonClient = State(initialValue: splitDaemonClient)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if coordinator.allReady {
                    if vaultSession.state == .ready {
                        if connectionGate.state == .slotFree {
                            TunnelContentView(loader: tunnelsManager)
                        } else {
                            ConnectionGateView()
                        }
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
            .environment(connectionGate)
            .tint(Color.accentColor)
            .frame(width: 560, height: 720)
            .onAppear {
                interfaceResolver.start()
                coordinator.start()
                connectionGate.currentTunnelsManager = { [tunnelsManager] in tunnelsManager.manager }
            }
            .onChange(of: coordinator.allReady) { _, ready in
                if !ready { vaultSession.invalidate() }
                if ready { tunnelsManager.manager?.releaseAbandonedStoreLatch() }
            }
            .task(id: vaultSession.state) {
                guard vaultSession.state == .ready else { return }
                connectionGate.start()
                connectionGate.checkAgain()
            }
            .task(id: coordinator.allReady) {
                guard coordinator.allReady else { return }
                let realign = await sessionCoordinator.boot { splitTunnelingStore.configuration }
                splitTunnelingStore.recordPush(realign)
            }
        }
        .windowResizability(.contentSize)
    }
}
