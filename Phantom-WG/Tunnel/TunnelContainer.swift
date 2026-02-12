import Foundation
import NetworkExtension

class TunnelContainer: ObservableObject, Identifiable {

    let tunnelProvider: TunnelProviding

    var id: String { tunnelProvider.localizedDescription ?? "" }

    @Published var name: String
    @Published var status: TunnelStatus
    @Published var lastActivationError: TunnelActivationError?

    var tunnelConfig: TunnelConfig? {
        tunnelProvider.tunnelConfig
    }

    var activateOnDemandSetting: ActivateOnDemandOption {
        ActivateOnDemandOption.from(provider: tunnelProvider)
    }

    var isActivateOnDemandEnabled: Bool {
        tunnelProvider.isOnDemandEnabled
    }

    // Activation tracking (used by TunnelsManager)
    var onDeactivated: ((TunnelContainer) -> Void)?
    var isAttemptingActivation = false
    var activationAttemptId: String?
    var activationTimer: Timer?

    init(tunnel: TunnelProviding) {
        tunnelProvider = tunnel
        name = tunnel.localizedDescription ?? ""
        status = TunnelStatus(from: tunnel.connectionStatus)
    }

    func refreshStatus() {
        status = TunnelStatus(from: tunnelProvider.connectionStatus)
    }
}
