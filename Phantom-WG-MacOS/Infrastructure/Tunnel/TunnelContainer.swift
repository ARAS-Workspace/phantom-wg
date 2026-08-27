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
    /// @witness ActivationSeam.aSecondPressQueuesBehindAStopStillLanding
    /// @witness ActivationSeam.aStopTheSystemNeverFinishesCannotPinTheQueue
    @ObservationIgnored var stopIssuedAt: ContinuousClock.Instant?

    /// The one reading on which a session provably does not exist.
    var isKnownInactive: Bool {
        tunnelProvider.connectionStatus == .disconnected
    }

    /// The one gate for user-facing doors that rewrite or remove this row's
    /// stored configuration (Edit's open AND submit, Delete). True only when
    /// every axis it reads is at rest: the live reading proves no session
    /// (`isKnownInactive`), the painted row concurs (`.inactive` — which keeps
    /// the gate closed on `.unknown`, on a queued `.waiting` row, and on any
    /// transitional paint), the activation flag is down, and no COUNTED stop
    /// is waiting on its rule. Two boundaries, named on purpose. The stop
    /// axis sees only the parked disarms that raise `pendingDisarmCount`;
    /// the full set of deferred stand-down saves lives in `DisarmSaveLedger`,
    /// and write ORDER against those saves is enforced where the writes
    /// happen — `modify`/`remove` await the ledger before their own save —
    /// not by this gate. The attempt axis reads the flag, not
    /// `activationAttemptId`: after a drop, the belt's verdict task still
    /// owns the row through its attemptId while the flag is already down, so
    /// this gate is open across that window and the verdict writers guard
    /// themselves on the id. Every user-facing door reads this one predicate,
    /// never its pieces; the reconcile-side realign is not such a door — it
    /// reads the pieces it needs, deliberately (#8) — and Delete's CONFIRM
    /// re-reads nothing here: the confirmed action carries its own
    /// stop-and-wait path (`startDeactivation`, then `remove()`'s bounded
    /// waits), by decision. On observation: the flag and the live reading are
    /// not observable on their own — this gate's value moves with transitions
    /// that also write status, the counter, or an error in the same tick, so
    /// a flag-only transition must bring a repaint with it.
    var isSettledInactive: Bool {
        isKnownInactive
            && status == .inactive
            && !isAttemptingActivation
            && pendingDisarmCount == 0
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
        clearStopSurvivorOnceGone()
    }

    /// "Connected again after the stop request" names a session. Once the live
    /// reading proves that session no longer exists, the sentence has nothing
    /// left to name and comes down at the same paint that shows the down row.
    /// The proof here is the pair the system has walked away from: a live
    /// `.disconnected` or a live `.invalid`. Any other reading may still name
    /// a session — `.disconnecting` included — so the sentence deliberately
    /// stays up there, and while any flow still owns the row (a stop waiting
    /// on its rule, an activation attempt) those flows write their own
    /// verdicts.
    func clearStopSurvivorOnceGone() {
        guard case .connectedDespiteStopRequest = lastActivationError else { return }
        let live = tunnelProvider.connectionStatus
        guard live == .disconnected || live == .invalid else { return }
        guard pendingDisarmCount == 0, !isAttemptingActivation else { return }
        lastActivationError = nil
    }

    /// A verified stand-down (`.done`) refutes BOTH stop sentences at once:
    /// the refusal named a save the system threw back, the unconfirmed
    /// sentence named a save whose answer never came — a disarm save that
    /// provably landed closes each question. An activation attempt that owns
    /// the row keeps its own verdicts (`attemptId` guard). Callers reach this
    /// only from `.done` terminals.
    func clearStopRefusalOnceDisarmed() {
        guard activationAttemptId == nil else { return }
        switch lastActivationError {
        case .stopDisarmRefused, .stopRuleStandDownUnconfirmed:
            lastActivationError = nil
        default:
            break
        }
    }

    /// @witness ActivationSeam.aSessionTheRuleBringsBackIsShownNotFought
    func clearErrorOnRise() {
        guard status == .active || status == .reasserting else { return }
        // Three stop sentences survive a rise, in one shape. None carries an
        // attempt conjunct, by decision: the writers of these sentences guard
        // themselves on the attemptId, so the switch here reads only the
        // sentence. Exhaustive on purpose — a new sentence in TunnelErrors
        // must answer here whether it survives a rise.
        switch lastActivationError {
        case .stopDisarmRefused, .connectedDespiteStopRequest:
            return
        // The unconfirmed sentence is about the RULE's save, not the session:
        // a rise does not refute it — the rule bringing the session back is
        // that sentence's most likely sequel.
        case .stopRuleStandDownUnconfirmed:
            return
        case .startingFailed, .savingFailed, .loadingFailed,
             .retryLimitReached, .failedWhileActivating,
             .foreignSlotHolder, .activationUnresolved, nil:
            lastActivationError = nil
        }
    }
}
