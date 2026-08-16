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
        // The gate needs the daemon clients: each controller carries an
        // identity probe so the boot pass can measure instead of
        // blindly activating.
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
                    // Second lock: PhantomTunnel and TunnelVault exist
                    // together or not at all — no session, no list.
                    if vaultSession.state == .ready {
                        // Third lock: the system's one VPN slot. When
                        // another local user's session holds it, the
                        // list would only offer activations that feed
                        // the cross-user on-demand fight — the gate
                        // names the situation instead and releases
                        // itself the moment the slot is freed.
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
            // Fixed: the layout is designed at this size. Wide enough
            // that a 44-character base64 key sits on one line with
            // room to spare — the configuration screens are dense
            // with monospaced values.
            .frame(width: 560, height: 720)
            .onAppear {
                interfaceResolver.start()
                coordinator.start()
                // Installed here because here is the only place that is
                // before everything. The manager cannot be handed over
                // at readiness — the view that creates it renders only
                // once the gate has already reported a free slot — so
                // the gate is given a way to ASK instead, and asks when
                // its sweep needs the answer.
                // The LOADER is captured, not `self`: this is a struct,
                // so an implicit capture would copy the whole App —
                // including the `State` box holding the gate — and the
                // gate would then transitively retain itself. Harmless
                // where both live for the process, and a trap anywhere
                // it is copied from.
                connectionGate.currentTunnelsManager = { [tunnelsManager] in tunnelsManager.manager }
            }
            .onChange(of: coordinator.allReady) { _, ready in
                // A gate that drops voids the session proof: a
                // reinstalled extension is a cold one, and the next
                // entry must probe again rather than trust a stale
                // `.ready`.
                if !ready { vaultSession.invalidate() }
                // The backstop for a teardown that never returned, and
                // no longer the primary one. The flow lowers the latch
                // from a `defer`, and the case a `defer` cannot reach —
                // an approval prompt nobody answers — is now bounded at
                // the wait itself (`deactivate()` carries a budget), so
                // that flow ends and its `defer` runs.
                //
                // This stays because it covers what a per-request budget
                // cannot: a latch raised by a task the system tore down
                // some other way, leaving no exit to run at all. What it
                // does NOT cover is the parked-prompt case it was
                // written for — this is an EDGE, and a parked teardown
                // leaves the gate sitting at ready without moving, so
                // nothing fires here. That gap is why the budget exists;
                // do not delete one believing the other has it.
                //
                // Readiness is what entitles this caller rather than a
                // guess about the world: the teardown exists to take the
                // extensions DOWN, so their return says no teardown of
                // theirs is running, whatever a stranded continuation
                // still believes.
                if ready { tunnelsManager.manager?.releaseAbandonedStoreLatch() }
            }
            .task(id: vaultSession.state) {
                // The slot verdict needs the vault to answer ownership,
                // so the connection gate arms only at readiness — and
                // re-checks on every return to it (a re-proven session
                // means the world may have changed underneath).
                guard vaultSession.state == .ready else { return }
                connectionGate.start()
                connectionGate.checkAgain()
            }
            .task(id: coordinator.allReady) {
                // Boot reconcile once the gate clears. The session
                // coordinator reads the live extension state (an NE
                // session survives app close/reopen) and adopts it
                // as the initial coordinator state. Honors persisted intent
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
