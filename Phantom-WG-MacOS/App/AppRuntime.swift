import SwiftUI

@MainActor
final class AppRuntime {

    let coordinator: ExtensionGateCoordinator
    let sessionCoordinator: SplitTunnelingSessionCoordinator
    let tunnelsManager: TunnelsManagerLoader
    let splitTunnelingStore: SplitTunnelingStore
    let splitProviderManager: SplitTunnelProviderManager
    let dnsProviderManager: DNSProxyProviderManager
    let dnsDaemonClient: DNSProxyDaemonClient
    let splitDaemonClient: SplitTunnelDaemonClient
    let interfaceResolver: PhysicalInterfaceResolver
    let toastCenter: ToastCenter
    let vaultClient: TunnelVaultClient
    let vaultSession: TunnelVaultSession
    let connectionGate: ConnectionGateCoordinator

    init() {
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

        self.coordinator = coordinator
        self.sessionCoordinator = sessionCoordinator
        self.tunnelsManager = tunnelsManager
        self.splitTunnelingStore = splitTunnelingStore
        self.splitProviderManager = splitProviderManager
        self.dnsProviderManager = dnsProviderManager
        self.interfaceResolver = PhysicalInterfaceResolver()
        self.toastCenter = ToastCenter()
        self.vaultClient = vaultClient
        self.vaultSession = TunnelVaultSession(vault: vaultClient)
        self.connectionGate = ConnectionGateCoordinator(vault: vaultClient)
        self.dnsDaemonClient = dnsDaemonClient
        self.splitDaemonClient = splitDaemonClient
    }

    var isIdle: Bool {
        (tunnelsManager.manager?.isIdle ?? true) && coordinator.isIdle && sessionCoordinator.isIdle
    }
}

@Observable
@MainActor
final class AppRuntimeHost {

    private(set) var runtime: AppRuntime?

    @ObservationIgnored private var drain: Task<Void, Never>?

    func windowOpened() {
        drain?.cancel()
        drain = nil
        if runtime == nil {
            runtime = AppRuntime()
        }
    }

    func windowClosed() {
        guard runtime != nil, drain == nil else { return }
        drain = Task { [weak self] in
            while let runtime = self?.runtime, !runtime.isIdle {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled, let self else { return }
            self.runtime = nil
            self.drain = nil
        }
    }
}
