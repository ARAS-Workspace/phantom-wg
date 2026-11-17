import SwiftUI

struct MainWindowRoot: View {
    let host: AppRuntimeHost

    var body: some View {
        Group {
            if let runtime = host.runtime {
                MainWindowContent(runtime: runtime)
            } else {
                Color.clear
            }
        }
        .onAppear { host.windowOpened() }
    }
}

struct MainWindowContent: View {
    let runtime: AppRuntime

    var body: some View {
        Group {
            if runtime.coordinator.allReady {
                if runtime.vaultSession.state == .ready {
                    if runtime.connectionGate.state == .slotFree {
                        TunnelContentView(loader: runtime.tunnelsManager)
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
        .environment(runtime.coordinator)
        .environment(runtime.sessionCoordinator)
        .environment(runtime.splitTunnelingStore)
        .environment(runtime.splitProviderManager)
        .environment(runtime.dnsProviderManager)
        .environment(runtime.dnsDaemonClient)
        .environment(runtime.splitDaemonClient)
        .environment(runtime.interfaceResolver)
        .environment(runtime.toastCenter)
        .environment(runtime.vaultClient)
        .environment(runtime.vaultSession)
        .environment(runtime.connectionGate)
        .onAppear {
            runtime.interfaceResolver.start()
            runtime.coordinator.start()
            runtime.connectionGate.currentTunnelsManager = { [loader = runtime.tunnelsManager] in loader.manager }
        }
        .onChange(of: runtime.coordinator.allReady) { _, ready in
            if !ready { runtime.vaultSession.invalidate() }
            if ready { runtime.tunnelsManager.manager?.releaseAbandonedStoreLatch() }
        }
        .task(id: runtime.vaultSession.state) {
            guard runtime.vaultSession.state == .ready else { return }
            runtime.connectionGate.start()
            runtime.connectionGate.checkAgain()
        }
        .task(id: runtime.coordinator.allReady) {
            guard runtime.coordinator.allReady else { return }
            let realign = await runtime.sessionCoordinator.boot { runtime.splitTunnelingStore.configuration }
            runtime.splitTunnelingStore.recordPush(realign)
        }
    }
}
