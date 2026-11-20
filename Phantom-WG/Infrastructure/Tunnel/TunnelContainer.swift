import Foundation
import NetworkExtension

@Observable
class TunnelContainer: Identifiable {

    @ObservationIgnored let tunnelProvider: TunnelProviding

    /// Stable identity captured at init. Using the persisted `TunnelConfig.id`
    /// keeps `ForEach` diffing correct across renames — unlike the display
    /// name, the UUID never changes once the tunnel is saved. A fresh UUID
    /// is the fallback for a tunnel whose Keychain payload cannot be
    /// read — and since it is minted per container, reload never matches
    /// such a tunnel by identity again.
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

    /// Whether the recovery rule is armed (NE's `isOnDemandEnabled`) —
    /// true for the tunnel the system is committed to reviving.
    var isActivateOnDemandEnabled: Bool {
        tunnelProvider.isOnDemandEnabled
    }

    /// Whether the system still holds a recovery rule for this tunnel.
    /// Standing a rule down clears `isOnDemandEnabled` and leaves the rule
    /// list in place, so a tunnel whose stand-down save was refused reads
    /// false for the flag while the system still carries the rule it acts
    /// on. Anything deciding whether a rule needs taking down reads this,
    /// not the flag.
    /// @witness ActivationSeam.theSweepReachesARuleTheFlagDenies
    /// @witness ActivationSeam.aStopReachesARuleTheFlagDenies
    var carriesRecoveryRule: Bool {
        tunnelProvider.isOnDemandEnabled || !(tunnelProvider.onDemandRules ?? []).isEmpty
    }

    // Activation tracking (used by TunnelsManager). These are internal
    // state — excluded from observation tracking so they don't invalidate
    // views that have no visibility into activation bookkeeping.
    @ObservationIgnored var isAttemptingActivation = false
    @ObservationIgnored var activationAttemptId: String?
    @ObservationIgnored var activationTask: Task<Void, Never>?

    init(tunnel: TunnelProviding) {
        tunnelProvider = tunnel
        id = tunnel.tunnelConfig?.id ?? UUID()
        name = tunnel.localizedDescription ?? ""
        status = TunnelStatus(from: tunnel.connectionStatus)
    }

    /// The gate a delete or an edit of this tunnel passes: the system reads
    /// no session (disconnected, or invalid as an entry saved disabled
    /// reads), the row is painted at rest, and no activation attempt is
    /// under way.
    /// Mac 2.2.1's `isSettledInactive` is the source; iOS keeps no disarm
    /// ledger, so Mac's fourth axis, a counted stop waiting on its rule, is
    /// not read here.
    ///
    /// @witness TunnelBulkDelete.aMixedSelectionDeletesOnlyTheSettledRows
    /// @witness TunnelBulkDelete.aSettledSelectionDeletesWhole
    /// @witness TunnelBulkDelete.theGateReadsTheSystemTheRowAndTheAttempt
    /// @witness TunnelBulkDelete.selectAllMarksTheRowsTheGateLetsGo
    var isSettledInactive: Bool {
        TunnelStatus(from: tunnelProvider.connectionStatus) == .inactive
            && status == .inactive
            && !isAttemptingActivation
    }

    /// States the manager holds on its own: a queued tunnel, and an
    /// activation attempt still on its retry ladder. The system reads
    /// both as "no session", so a refresh does not write that reading
    /// over them; a reading that says a session exists still lands.
    var isManagerDriven: Bool {
        switch status {
        case .waiting: return true
        case .activating, .reasserting: return isAttemptingActivation
        case .inactive, .active, .deactivating: return false
        }
    }

    /// @witness ActivationSeam.aListRefreshCannotCancelAnActivation
    /// @witness ActivationSeam.aListRefreshCannotTakeAQueuedTunnelsTurn
    func refreshStatus() {
        let derived = TunnelStatus(from: tunnelProvider.connectionStatus)
        if isManagerDriven, derived == .inactive || derived == .deactivating { return }
        status = derived
    }
}
