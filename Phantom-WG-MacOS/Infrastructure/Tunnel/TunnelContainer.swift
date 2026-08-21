import Foundation
import NetworkExtension

@Observable
class TunnelContainer: Identifiable {

    @ObservationIgnored let tunnelProvider: TunnelProviding

    let id: UUID

    var name: String
    var status: TunnelStatus
    var lastActivationError: TunnelActivationError?

    var identity: TunnelIdentity? {
        tunnelProvider.tunnelIdentity
    }

    var isGhost: Bool {
        identity?.isGhost ?? false
    }

    var isActivateOnDemandEnabled: Bool {
        tunnelProvider.isOnDemandEnabled
    }

    @ObservationIgnored var isAttemptingActivation = false
    @ObservationIgnored var activationAttemptId: String?
    @ObservationIgnored var activationTask: Task<Void, Never>?
    @ObservationIgnored var activationRungTask: Task<Void, Never>?
    @ObservationIgnored var pendingDisarmTask: Task<Void, Never>?
    var pendingDisarmCount = 0

    var stopIsWaitingOnItsRule: Bool {
        pendingDisarmCount > 0 && (status == .active || status == .reasserting)
    }
    @ObservationIgnored var respawnReviveConsumed = false
    @ObservationIgnored var respawnReviveTask: Task<Void, Never>?

    init(tunnel: TunnelProviding) {
        tunnelProvider = tunnel
        id = tunnel.tunnelIdentity?.id ?? UUID()
        name = tunnel.localizedDescription ?? ""
        status = TunnelStatus(from: tunnel.connectionStatus)
    }

    var isManagerDriven: Bool {
        switch status {
        case .waiting: return true
        case .activating, .reasserting: return isAttemptingActivation
        case .inactive, .active, .deactivating: return false
        }
    }

    func refreshStatus() {
        let derived = TunnelStatus(from: tunnelProvider.connectionStatus)
        if isManagerDriven, derived == .inactive || derived == .deactivating { return }
        status = derived
        clearErrorOnRise()
    }

    func clearStopRefusalOnceDisarmed() {
        guard case .stopDisarmRefused = lastActivationError, activationAttemptId == nil else { return }
        lastActivationError = nil
    }

    func clearErrorOnRise() {
        guard status == .active || status == .reasserting else { return }
        if case .stopDisarmRefused = lastActivationError, activationAttemptId == nil { return }
        lastActivationError = nil
    }
}
