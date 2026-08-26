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
        pendingDisarmCount > 0
    }

    /// The moment this manager last issued a stop to the system. Written by
    /// `performDeactivation` alone and never cleared: the window it opens is
    /// closed by arithmetic, not by any writer.
    /// @witness ActivationSeam.aStopTheRuleSaveCannotAnswerStillGoesOut
    @ObservationIgnored var stopIssuedAt: ContinuousClock.Instant?

    /// The one reading on which a session provably does not exist.
    var isKnownInactive: Bool {
        tunnelProvider.connectionStatus == .disconnected
    }

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
        case .inactive, .active, .deactivating, .unknown: return false
        }
    }

    /// @witness ActivationSeam.refreshCannotCancelActivation
    func refreshStatus() {
        let system = tunnelProvider.connectionStatus
        let derived = TunnelStatus(from: system)
        if isManagerDriven, derived == .inactive || derived == .deactivating || derived == .unknown { return }
        status = derived
        clearErrorOnRise()
    }

    func clearStopRefusalOnceDisarmed() {
        guard case .stopDisarmRefused = lastActivationError, activationAttemptId == nil else { return }
        lastActivationError = nil
    }

    /// @witness ActivationSeam.aSessionTheRuleBringsBackIsShownNotFought
    func clearErrorOnRise() {
        guard status == .active || status == .reasserting else { return }
        if case .stopDisarmRefused = lastActivationError, activationAttemptId == nil { return }
        if case .connectedDespiteStopRequest = lastActivationError { return }
        lastActivationError = nil
    }
}
