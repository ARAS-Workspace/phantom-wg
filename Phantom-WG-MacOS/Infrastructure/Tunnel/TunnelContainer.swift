import Foundation
import NetworkExtension

@Observable
class TunnelContainer: Identifiable {

    @ObservationIgnored let tunnelProvider: TunnelProviding

    /// Stable identity captured at init. Using the persisted
    /// `TunnelIdentity.id` keeps `ForEach` diffing correct across
    /// renames — unlike the display name, the UUID never changes once
    /// the tunnel is saved. A fresh UUID is used as fallback for
    /// transient states where no identity is attached.
    let id: UUID

    var name: String
    var status: TunnelStatus
    var lastActivationError: TunnelActivationError?

    /// The secret-free projection the system's preferences hold. The
    /// configuration itself comes from the vault, asynchronously.
    var identity: TunnelIdentity? {
        tunnelProvider.tunnelIdentity
    }

    var isGhost: Bool {
        identity?.isGhost ?? false
    }

    /// Whether the recovery rule is armed (NE's `isOnDemandEnabled`) —
    /// true for the tunnel the system is committed to reviving.
    var isActivateOnDemandEnabled: Bool {
        tunnelProvider.isOnDemandEnabled
    }

    // Activation tracking (used by TunnelsManager). These are internal
    // state — excluded from observation tracking so they don't invalidate
    // views that have no visibility into activation bookkeeping.
    @ObservationIgnored var isAttemptingActivation = false
    @ObservationIgnored var activationAttemptId: String?
    /// The scheduled NEXT rung — a sleep that fires the retry. Cancel
    /// it and no further rung is climbed.
    @ObservationIgnored var activationTask: Task<Void, Never>?
    /// The rung running RIGHT NOW. Cancelling it buys nothing (its
    /// awaits are NE round-trips, which are not cancellable), but
    /// AWAITING it is worth everything: it is the only way to know
    /// that a `savePreferences` already on its way to the system has
    /// landed. `remove()` uses exactly that before it deletes.
    @ObservationIgnored var activationRungTask: Task<Void, Never>?
    /// One in-app revive per user intent, for the respawn-window class
    /// where the system drops a just-started session without an error
    /// record. Granted (reset) by `startActivation(of:)`, spent by the
    /// disconnect observer — the revive path re-enters below the
    /// public door precisely so it can never re-grant itself.
    @ObservationIgnored var respawnReviveConsumed = false
    /// The pending revive, held so every intent withdrawal (a stop, a
    /// newer start elsewhere, a ground sweep, a remove) can cancel it
    /// — a delayed re-activation firing behind a green sweep would
    /// falsify the sweep.
    @ObservationIgnored var respawnReviveTask: Task<Void, Never>?

    init(tunnel: TunnelProviding) {
        tunnelProvider = tunnel
        id = tunnel.tunnelIdentity?.id ?? UUID()
        name = tunnel.localizedDescription ?? ""
        status = TunnelStatus(from: tunnel.connectionStatus)
    }

    func refreshStatus() {
        status = TunnelStatus(from: tunnelProvider.connectionStatus)
    }
}
