import Foundation
import NetworkExtension

@Observable
class TunnelContainer: Identifiable {

    @ObservationIgnored let tunnelProvider: TunnelProviding

    /// Stable identity captured at init. Using the persisted `TunnelConfig.id`
    /// keeps `ForEach` diffing correct across renames — unlike the display
    /// name, the UUID never changes once the tunnel is saved. A fresh UUID
    /// is used as fallback for transient states where no config is attached.
    let id: UUID

    var name: String
    var status: TunnelStatus
    var lastActivationError: TunnelActivationError?

    var tunnelConfig: TunnelConfig? {
        tunnelProvider.tunnelConfig
    }

    /// Ghost when the persisted config carries a wstunnel bridge.
    var isGhost: Bool {
        tunnelConfig?.isGhostMode ?? false
    }

    var activateOnDemandSetting: ActivateOnDemandOption {
        ActivateOnDemandOption.from(provider: tunnelProvider)
    }

    var isActivateOnDemandEnabled: Bool {
        tunnelProvider.isOnDemandEnabled
    }

    // Activation tracking (used by TunnelsManager). These are internal
    // state — excluded from observation tracking so they don't invalidate
    // views that have no visibility into activation bookkeeping.
    @ObservationIgnored var onDeactivated: ((TunnelContainer) -> Void)?
    @ObservationIgnored var isAttemptingActivation = false
    @ObservationIgnored var activationAttemptId: String?
    @ObservationIgnored var activationTask: Task<Void, Never>?

    init(tunnel: TunnelProviding) {
        tunnelProvider = tunnel
        id = tunnel.tunnelConfig?.id ?? UUID()
        name = tunnel.localizedDescription ?? ""
        status = TunnelStatus(from: tunnel.connectionStatus)
    }

    func refreshStatus() {
        status = TunnelStatus(from: tunnelProvider.connectionStatus)
    }
}
