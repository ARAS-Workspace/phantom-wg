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

    /// The recovery flag as THIS PROCESS last wrote it (NE's
    /// `isOnDemandEnabled`), which is not the same thing as the rule
    /// the system would revive on: a disarm save that was refused, or
    /// that never answered at all, leaves this reading and the store
    /// disagreeing. So it reports and it displays, and WHETHER a rule
    /// comes down may not be decided from it — `standDownRecovery`
    /// re-reads for exactly that reason, and the rung-0 sweep stopped
    /// filtering on this value because filtering skipped precisely the
    /// rows where the two had parted. One decision still rests on it,
    /// named here so it is not mistaken for the old habit: the ORDER of
    /// the stop's own disarm, where a lying flag costs at most one
    /// revive bounce before the repair lands.
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

    /// True while this row's status is the manager's to write rather
    /// than the system's to report. Narrower than "an attempt is in
    /// flight": it is the row being driven UP.
    ///
    /// `.waiting` is a queue slot with no session behind it, which
    /// `TunnelStatus(from:)` cannot produce at all. `.activating` and
    /// `.reasserting` under an attempt of ours are what a rung is
    /// working to leave, and they are exactly the two states the rung's
    /// own post-await guards accept.
    ///
    /// The other three are excluded on purpose, and one of them the
    /// hard way. `.active` and `.deactivating` NEED the system's
    /// lowering reading — for one it is the session ending, for the
    /// other it is the stop landing — and `.inactive` has nothing left
    /// to lower. Keying on the attempt flag alone swept `.deactivating`
    /// in with them, and that cost a row its last way out: a
    /// `.disconnecting` arriving mid-activation paints `.deactivating`
    /// without clearing the flag, and the rung then closes on its own
    /// guard with no ladder left. The system's own `.disconnected` tail
    /// normally grounds the row a moment later; when that notification
    /// never arrives the reload was the only writer left, and this gate
    /// had taken it away. What made that terminal rather than untidy is
    /// the surrounding UI: Delete and Edit are disabled off `.inactive`
    /// and toggling off returns early on `.deactivating` without
    /// lowering the flag, so the user has no move either. (The
    /// activation ceiling's watchdog has since become a second writer
    /// for that row — it withdraws the attempt at the ceiling — which
    /// turns the cost of a repeat of this mistake from permanent into
    /// ceiling-long. Smaller is not small; the exclusion stays.)
    ///
    /// That second writer only holds because the watchdog reads the
    /// LEDGER rather than the row: a `.deactivating` row this gate
    /// lets a refresh ground to `.inactive` still carries a live
    /// attempt, and the watchdog admits it on exactly those terms. The
    /// gate opening on `.inactive` is therefore not a way out of the
    /// attempt — it is a way for the row to be grounded while the
    /// attempt stays owned.
    var isManagerDriven: Bool {
        switch status {
        case .waiting: return true
        case .activating, .reasserting: return isAttemptingActivation
        case .inactive, .active, .deactivating: return false
        }
    }

    /// Takes the system's reading of this session, unless the row is
    /// the manager's to write and the reading would take it DOWN.
    ///
    /// `.inactive` and `.deactivating` are the two derived values that
    /// lower a row, and neither is news while the manager drives it: a
    /// tunnel being started already knows no session is up yet, and a
    /// queue slot has no session for the system to report on at all.
    /// Landing them anyway is what silently cancelled activations — the
    /// rung's next guard wants `.activating` or `.reasserting`, so a
    /// lowered row closed it with no error, no retry and no log — and
    /// what took a queued tunnel's turn away before it ever started.
    /// `.activating`, `.active` and `.reasserting` still land, so a
    /// session that really did come up is never hidden.
    ///
    /// Testing the MAPPED value rather than the raw one is deliberate:
    /// `TunnelStatus(from:)` funnels `.invalid` and any unrecognized
    /// future case to `.inactive`, so both are covered by the same test
    /// instead of each needing its own.
    ///
    /// Four callers reach this gate, and they are the only writes
    /// that DERIVE the row from the system's reading: the reload's
    /// `ingest`, the status observer's non-attempting branch, the
    /// activation watchdog's withdrawal, and the rung save-catch —
    /// the last two lower the attempt flag before they derive, which
    /// opens the gate everywhere but the one place it must stay shut:
    /// a row the queue has since taken is `.waiting`, manager-driven
    /// whatever the flag says, and the save-catch's lowering derive
    /// is rightly refused there. Everything else
    /// that writes `status` is the manager writing its own decision —
    /// the rung's optimistic paint, the queue slot, the other give-up
    /// exits, `performDeactivation`, the uninstall sweep, and the observer's
    /// attempting branch, which belongs to the drop belt and owns a
    /// drop during an attempt. The gate has nothing to say to any of
    /// them, so this is not a chokepoint for `status`; it is a
    /// chokepoint for the system's opinion of it.
    func refreshStatus() {
        let derived = TunnelStatus(from: tunnelProvider.connectionStatus)
        if isManagerDriven, derived == .inactive || derived == .deactivating { return }
        status = derived
    }
}
