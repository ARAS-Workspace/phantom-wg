import Foundation
import NetworkExtension

// MARK: - Activation & Deactivation

extension TunnelsManager {

    func startActivation(of tunnel: TunnelContainer) {
        // A tunnel being deleted is not startable, however inactive it
        // looks: `remove()` hangs on the vault for seconds with the
        // detail sheet still up, and a toggle tapped in that window
        // would arm and save an entry the next line is about to erase.
        guard !removingIds.contains(tunnel.id) else { return }
        // Grant only on an ACCEPTED intent: a duplicate start on a
        // non-inactive tunnel is a no-op and must not re-arm the
        // revive mid-attempt.
        guard tunnel.status == .inactive else { return }
        // A newer intent ANYWHERE withdraws every older pending
        // revive first — reviving tunnel A after the user chose B
        // would override the freshest intent with a stale one.
        for other in tunnels {
            other.respawnReviveConsumed = true
            other.respawnReviveTask?.cancel()
            other.respawnReviveTask = nil
        }
        // Then this fresh intent grants its one revive. The revive
        // re-enters through `beginActivation` below this door, so a
        // revived attempt can never re-grant itself into a loop.
        tunnel.respawnReviveConsumed = false
        beginActivation(of: tunnel)
    }

    /// Everything the public door does except granting the respawn
    /// revive: exclusive-slot queueing, and rung 0 when the slot is
    /// free. The disconnect observer's one-shot revive enters here.
    ///
    /// The disarm-others sweep is NOT here — it stands on rung 0, so
    /// that the queue hand-off, which never passes through this door,
    /// gets it too.
    func beginActivation(of tunnel: TunnelContainer) {
        // Barred here too, not only at the rung below: this door
        // reshuffles state before it gets there — it can park the
        // tunnel as `.waiting` and stop whichever tunnel is active —
        // and none of that should happen for an entry being deleted.
        guard !removingIds.contains(tunnel.id) else { return }
        guard tunnel.status == .inactive else { return }

        if let activeTunnel = tunnels.first(where: { $0.status != .inactive && $0.status != .waiting }) {
            if let previousWaiting = waitingTunnel, previousWaiting.id != tunnel.id {
                previousWaiting.status = .inactive
            }
            tunnel.status = .waiting
            waitingTunnel = tunnel
            startDeactivation(of: activeTunnel)
            return
        }

        startActivation(of: tunnel, at: 0)
    }

    func startDeactivation(of tunnel: TunnelContainer) {
        // A stop is the withdrawal of the intent that granted the
        // revive: spend it and cancel any pending one BEFORE any
        // async window (the armed stop's disarm save below suspends)
        // can let a spontaneous drop race a revive up against the
        // user's explicit stop.
        tunnel.respawnReviveConsumed = true
        tunnel.respawnReviveTask?.cancel()
        tunnel.respawnReviveTask = nil
        guard tunnel.status != .inactive && tunnel.status != .deactivating else { return }

        // The intent comes down HERE, synchronously, before any branch
        // below can suspend. The armed path saves first and only then
        // reaches `performDeactivation`, so withdrawing there left a
        // whole NE round-trip in which the rung still read
        // `.activating` with a matching attempt id: it walked past
        // both guards, re-armed the rule the user was withdrawing, and
        // started the tunnel. A stop that a start can answer is not a
        // stop. Same reason the drop belt must not see this as a
        // mid-activation drop: with the flag down it takes the plain
        // status branch instead of writing "session ended" over the
        // user's own decision.
        tunnel.isAttemptingActivation = false
        tunnel.activationAttemptId = nil
        tunnel.activationTask?.cancel()
        tunnel.activationTask = nil

        // A waiting tunnel has not started yet: toggling it off cancels
        // the queued activation. Sending stop to a session the system
        // never brought up draws no status callback, so it would strand
        // in `.deactivating` — clear the queue slot and return to idle.
        if tunnel.status == .waiting {
            if waitingTunnel?.id == tunnel.id { waitingTunnel = nil }
            tunnel.status = .inactive
            return
        }

        // Stand the recovery rule down first — with it armed, the
        // system would reconnect the moment the tunnel drops.
        if tunnel.isActivateOnDemandEnabled {
            Task {
                // The gate carries the liveness bars, read when the
                // save RUNS. The window they close is narrow here and
                // worth naming precisely, so nobody later mistakes it
                // for the common path: the Delete button is disabled
                // unless the tunnel is inactive, so `deleteTunnel`'s
                // stop-then-remove pair only fires when the tunnel
                // came UP between the confirmation dialog opening and
                // the user confirming — an on-demand rule reconnecting
                // it, or the respawn revive. Narrow, but the cost of
                // losing that race is a re-minted entry the app can no
                // longer see or delete.
                let outcome = await guardedStandDown(tunnel, loggingRefusal: false)
                if case .barred = outcome { return }
                // A newer intent may have been granted while that save
                // was in flight — the user changed their mind twice.
                // The withdrawal above set the attempt id to nil, so
                // anything else there is a start that outranks this
                // stop, and finishing it would tear down the session
                // that start is bringing up.
                guard tunnel.activationAttemptId == nil else { return }
                if case .refused(let disarmError) = outcome {
                    // Two facts to report, and both go out: the rule
                    // could not be stood down (so the system may
                    // reconnect this tunnel on its own), and the stop
                    // the user asked for still happens. Returning here
                    // instead — the previous shape — left the session
                    // running with its ladder already dismantled, so
                    // the tunnel could no longer be stopped at all.
                    tunnel.lastActivationError = .savingFailed(systemError: disarmError)
                }
                performDeactivation(of: tunnel)
            }
        } else {
            performDeactivation(of: tunnel)
        }
    }

    /// Uninstall-path sweep: stands every tunnel's recovery rule down
    /// before the extensions go, so the system does not fight the
    /// teardown by reviving a tunnel mid-deactivation — and the
    /// entries the flow deliberately leaves in place (custody rows
    /// keep theirs as the anchor for their broken payloads) never
    /// carry an armed rule into the extension-less void. Best-effort,
    /// like the rest of the uninstall path.
    func disarmAllRecovery() async {
        // Everything that could arm a rule after this sweep is
        // withdrawn first, or the sweep reports clean and something
        // re-arms behind it. Three sources, all real: a rung in flight
        // walks straight past `armRecovery` on its way to the start; a
        // scheduled retry climbs on its own five seconds later; and a
        // queued tunnel takes its turn the moment the active one goes
        // down, which is precisely what an uninstall is about to
        // cause. The pending revives go with them.
        waitingTunnel = nil
        for tunnel in tunnels {
            tunnel.isAttemptingActivation = false
            tunnel.activationAttemptId = nil
            tunnel.activationTask?.cancel()
            tunnel.activationTask = nil
            tunnel.respawnReviveConsumed = true
            tunnel.respawnReviveTask?.cancel()
            tunnel.respawnReviveTask = nil
            // Only the rows whose mover was just withdrawn: an
            // `.activating` tunnel has nothing left to advance it and
            // would spin until the app restarted, and a queued one
            // never had a session. `.deactivating` and `.reasserting`
            // are the system's to finish and stay the observer's.
            if tunnel.status == .activating || tunnel.status == .waiting {
                tunnel.status = .inactive
            }
        }
        // A rung already inside its save cannot be recalled, and it
        // arms on its way past. Waiting it out here is the same
        // contract `remove()` keeps, and for the same reason: without
        // it the sweep can report clean seconds before an armed rule
        // lands behind it. One deadline for the whole set, not one
        // each — this runs on the uninstall path, where the user is
        // waiting on a progress sheet.
        let rungs = tunnels.compactMap(\.activationRungTask)
        _ = await bounded(15) {
            for rung in rungs { await rung.value }
            return true
        }
        // Unconditional, no armed-filter: a tunnel whose flag reads
        // false may still hold the rule in the store from an earlier
        // refused save, and the sweep is the last chance to clear it
        // before the extensions go.
        for tunnel in tunnels {
            // Best-effort, but not blind: a rule that survives its
            // save is exactly what this sweep exists to prevent, and
            // the uninstall continues either way — so it gets said out
            // loud rather than swallowed by a `try?`.
            if let error = await Self.standDownRecovery(on: tunnel.tunnelProvider) {
                NSLog("[uninstall] recovery rule survived the sweep on \(tunnel.name) — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private

    /// The recovery rule: one connect-on-any-network on-demand rule,
    /// armed on every activation that passes the foreign-slot
    /// pre-flight. There is no user-facing switch — starting a tunnel
    /// is the recovery intent, stopping it withdraws it
    /// (`startDeactivation` disarms before it stops). The rule also
    /// stands down without a stop when another local user's session
    /// is proven to hold the slot: the collision belts here and the
    /// connection gate's engage sweep — an armed rule against an
    /// occupied slot only feeds the cross-user fight.
    private static func armRecovery(on provider: TunnelProviding) {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        provider.onDemandRules = [rule]
        provider.isOnDemandEnabled = true
    }

    /// Stands the recovery rule down and answers the memory-versus-
    /// store question honestly.
    ///
    /// Callers come in four families: the give-up paths that failed
    /// LOCALLY (a config that cannot load, a `startTunnel` that
    /// throws) where leaving the rule armed is a loop trap; the stop,
    /// hand-off and removal paths, where the user withdrew the intent;
    /// the collision paths, where a proven foreign slot holder makes
    /// an armed rule fuel for the cross-user fight; and the uninstall
    /// sweep. A timeout, or a dropped session with no holder in sight,
    /// is the opposite case and deliberately keeps its rule: that is
    /// the transient condition recovery exists to ride out.
    ///
    /// Disarming is two facts, not one: the flag in this process and
    /// the rule in the system store. Write the flag, let the save fail
    /// quietly, and this process reports the comfortable half — the
    /// callers here branch on the returned error, and the DEBUG
    /// harness counts armed tunnels by reading
    /// `isActivateOnDemandEnabled`, which is this flag.
    ///
    /// So a refused save does not get to guess. A failed write leaves
    /// the store in an unknown state (the rule may have landed and
    /// only the reply been lost), and this asks rather than assumes:
    /// one `loadPreferences` re-reads what is actually stored, and the
    /// flag then carries the store's own answer. Only when that
    /// re-read ALSO fails does it fall back — to what the flag was on
    /// entry, so a tunnel that came in armed stays reported armed
    /// (under-reporting a rule leaves the system reconnecting a tunnel
    /// the user stood down) and one that came in disarmed does not
    /// invent a rule it never had.
    ///
    /// It runs unconditionally, including on a tunnel that already
    /// looks disarmed: the flag being false is precisely what an
    /// earlier failed save leaves behind, and skipping on it would
    /// make this the one call that cannot repair that state.
    ///
    /// Returns nil when the rule is down for real. NOT the only place
    /// the rule comes down — the connection gate's engage sweep still
    /// writes the flag and saves by hand; it belongs to the gate's own
    /// package and should end up here.
    @discardableResult
    static func standDownRecovery(on provider: TunnelProviding) async -> Error? {
        // What was true before we touched it, so the pessimistic
        // fallback restores a fact instead of inventing one: a tunnel
        // that was never armed must not come back from a failed save
        // claiming a rule it never had.
        let wasArmed = provider.isOnDemandEnabled
        provider.isOnDemandEnabled = false
        do {
            try await provider.savePreferences()
            return nil
        } catch {
            if (try? await provider.loadPreferences()) == nil {
                provider.isOnDemandEnabled = wasArmed
            }
            return error
        }
    }

    /// Outcome of a gated disarm — see `guardedStandDown`.
    enum StandDownOutcome {
        case barred
        case done
        case refused(Error)
    }

    /// THE gate for every disarm save issued after a suspension point.
    /// A deferred save's liveness facts must be read when the save
    /// RUNS, never when it was decided: a save landing on an entry
    /// that is being deleted re-mints it in the system store, and one
    /// landing on an entry the list no longer holds writes to a row
    /// nobody owns. Those two bars used to be copied by hand at every
    /// deferred site — and every NEW site re-ran the lottery of
    /// remembering them; here they are read once, at issue time, for
    /// all of them. What stays accepted is the LANDING race ("issues,
    /// not completes"): a save already in flight when a removal starts
    /// can still land after it — the gate narrows that window to the
    /// flight itself, which is as far as an uncancellable surface
    /// allows. The membership bar is OBJECT identity, not id: a
    /// container evicted and re-minted under the same id is precisely
    /// the stale-provider-handle replay the house forbids ("no stale
    /// provider object is replayed") — the new container's rule
    /// belongs to its own lifecycle.
    ///
    /// Exempt by contract, not by oversight: the rung's own inline
    /// give-up disarms (a `remove()` WAITS the rung out before
    /// deleting, so an in-rung save cannot race a completed removal)
    /// `disarmAllRecovery` (unconditional by design — the uninstall
    /// sweep is the last chance to clear a rule whose flag lies), and
    /// `remove()`'s own sequenced disarm — it runs under its own
    /// `removingIds` entry, so routing it here would only bar itself.
    ///
    /// Refusals log in the standard format unless the caller carries
    /// its own reporting surface (the watchdog's truest-reading line,
    /// the stop's `savingFailed`).
    @discardableResult
    func guardedStandDown(
        _ tunnel: TunnelContainer,
        context: @autoclosure () -> String = "",
        loggingRefusal: Bool = true
    ) async -> StandDownOutcome {
        guard !removingIds.contains(tunnel.id),
              tunnels.contains(where: { $0 === tunnel }) else { return .barred }
        guard let error = await Self.standDownRecovery(on: tunnel.tunnelProvider) else {
            return .done
        }
        if loggingRefusal {
            let ctx = context()
            NSLog("[activation] recovery rule stayed armed on \(tunnel.name)\(ctx.isEmpty ? "" : " \(ctx)") — \(error.localizedDescription)")
        }
        return .refused(error)
    }

    // Sealed at size, on purpose: this is the ladder's single entrance,
    // and the bar, the exhausted exit, the sweep, the watchdog and the
    // rung are ONE reviewed narrative whose ordering is the contract —
    // splitting it would scatter exactly what the comments prove. The
    // thresholds stay live for the rest of the product.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func startActivation(of tunnel: TunnelContainer, at retryIndex: Int) {
        // The same bar, one level down: the public door is not the
        // only way in. The revive re-enters through `beginActivation`,
        // the queue hand-off calls this directly, and a scheduled
        // retry lands here on its own. One deletion has to close all
        // of them.
        guard !removingIds.contains(tunnel.id) else { return }
        guard retryIndex < maxRetries else {
            tunnel.isAttemptingActivation = false
            tunnel.activationTask?.cancel()
            tunnel.activationTask = nil
            tunnel.status = .inactive
            // The ladder ran out without the system ever reporting
            // connected or disconnected — there is no terminal system
            // error to show, only the timeout itself (a one-time stale
            // rung may have thrown and been reloaded past; a repeat
            // never reaches here, it exits terminal below). Recovery
            // stays armed on purpose: a timeout is transient (no network
            // or an unreachable server), exactly what on-demand rides
            // out — unless a tunnel is queued behind this one, in which
            // case the hand-off below climbs rung 0 and rung 0's sweep
            // gives the rule to whoever is activating now. Armed<=1
            // outranks keeping a transient rule.
            tunnel.lastActivationError = .retryLimitReached(
                lastSystemError: TunnelsManager.noSystemDetail(LocalizationManager.shared.t("error_detail_timeout")))
            // A give-up path like the others: a queued tunnel takes the
            // turn of the one that just failed. Unlike the `.disconnected`
            // observer, these direct exits draw no status callback, so
            // the hand-off has to be made here.
            activateWaitingTunnelIfNeeded()
            return
        }

        if retryIndex == 0 {
            // Disarm every other tunnel's recovery rule — recovery
            // belongs to the tunnel being activated now.
            //
            // This sits on rung 0 rather than at the public door
            // because the door is not the only way in. The queue
            // hand-off calls this method directly, and armed-and-
            // inactive is a normal resting state (an anonymous drop and
            // an exhausted ladder both keep their rule on purpose), so
            // a tunnel taking its turn that way used to arm its rule
            // beside one that was already armed. Every entrance climbs
            // rung 0, so every ladder now issues the sweep.
            //
            // Issues, not completes: the tasks below suspend inside
            // their own saves, so a sweep can still land after this
            // tunnel has armed. The invariant they serve is eventual —
            // one armed rule once the saves settle — not a happens-
            // before against `armRecovery`.
            //
            // Fire-and-forget in ordering only, never in outcome: the
            // old shape threw the save's answer away, so a refused
            // disarm left a second armed rule in the store while the
            // app counted one. On refusal the helper re-reads the store
            // and sets the flag to what is actually there, and the log
            // says which tunnel kept its rule.
            for other in tunnels where other.id != tunnel.id && other.isActivateOnDemandEnabled {
                Task {
                    // Liveness reads at RUN time, and both bars, live
                    // inside the gate — the site cannot forget them.
                    await guardedStandDown(other)
                }
            }

            tunnel.status = .activating
            tunnel.lastActivationError = nil
        }

        tunnel.isAttemptingActivation = true
        let attemptId = UUID().uuidString
        tunnel.activationAttemptId = attemptId

        // The floor under every other guard on this path: no attempt
        // may stay unresolved for ever.
        //
        // Three different things leave one that way, and they have
        // nothing in common except the outcome — an NE round-trip that
        // never answers, a `.disconnecting` whose `.disconnected` never
        // follows, and any rung that closes on one of its own guards
        // with nothing scheduled behind it. So this watches the
        // OUTCOME rather than the causes: past the ceiling, if the
        // attempt is still this one and still has nothing to show, the
        // manager withdraws it.
        //
        // It withdraws and never retries. Retrying would put a second
        // rung on top of a first that cannot be cancelled (NE
        // round-trips are not), and the single `activationRungTask`
        // handle would lose the live one. The bookkeeping it writes is
        // safe against the call still in flight — the attempt id goes
        // first, and every guard downstream fails closed on it — and
        // then it makes ONE store write, standing the rule down, which
        // genuinely does race that call. A REFUSED save is bounded the
        // way every disarm here is — the helper re-reads the store
        // rather than guessing — but this save rides the very surface
        // whose silence is the withdrawal's premise, so it can also
        // hang exactly like the call it suspects. That is accepted,
        // and it dictates the order below: the row, the error and the
        // queue hand-off are all written BEFORE the save, so nothing
        // user-facing ever waits on it. What a hang then costs is this
        // task (suspended, holding one container) and a flag reading
        // disarmed over a store that never confirmed — repaired by the
        // next activation of this row, which rewrites the rule
        // wholesale. (A removal would repair it too, but in the
        // wedged-save family its rung-wait rides the same silent
        // surface and times out first; the activation is the repair
        // that needs no luck.)
        //
        // No cancellation site, deliberately. Each of these tasks is
        // its own generation check — a later rung, a stop, a delete or
        // a written error all move one of the facts below — so a
        // watchdog that wakes into a resolved world is a no-op, and the
        // alternative was eight places that would have to remember.
        // The manager is held weakly across the sleep for the same
        // reason: a watchdog must not be what keeps a dead manager
        // alive for a whole ceiling.
        Task { [weak self] in
            guard let ceiling = self?.activationCeiling else { return }
            try? await Task.sleep(for: .seconds(ceiling))
            // The three facts that say the attempt is still unresolved,
            // plus the two that say this row is still ours to write —
            // the same pair every deferred writer on this path carries,
            // and load-bearing here because the lines below now include
            // a save. A row that is `.active`, `.inactive` or parked
            // `.waiting` is not an unresolved attempt: the first two
            // resolved, and the third belongs to the queue.
            guard let self,
                  tunnel.activationAttemptId == attemptId,
                  tunnel.isAttemptingActivation,
                  tunnel.lastActivationError == nil,
                  tunnel.status == .activating || tunnel.status == .reasserting
                    || tunnel.status == .deactivating,
                  !self.removingIds.contains(tunnel.id),
                  self.tunnels.contains(where: { $0 === tunnel }) else { return }
            // The floor is under SILENCE, and silence is the one fact
            // the row alone cannot supply. A system reading that says
            // a session exists — connecting, reasserting or connected
            // — is the system still speaking: the attempt is late,
            // not unresolved, and the observer's ordinary paths still
            // own its ending. Withdrawing here would stamp "the
            // system never reported why" over a session the system is
            // actively reporting, and stand down the very rule every
            // activated tunnel is promised. Read without writing —
            // landing a raising value is the observer's job. A session
            // the system holds at connecting for ever stays a spinner
            // the user can stop — in the armed wedged pair the first
            // tap withdraws the intent and disarms while its own save
            // rides the same silent surface, and the second tap then
            // sends the stop — honest, and strictly older than this
            // watchdog.
            let derived = TunnelStatus(from: tunnel.tunnelProvider.connectionStatus)
            guard derived == .inactive || derived == .deactivating else { return }
            NSLog("[activation] attempt on \(tunnel.name) never resolved — withdrawing it")
            tunnel.isAttemptingActivation = false
            tunnel.activationAttemptId = nil
            tunnel.activationTask?.cancel()
            tunnel.activationTask = nil
            // Re-derived rather than grounded flat: with the flag down
            // the gate is open, so this lands what the system actually
            // reads — `.inactive` for the wedged save (no session ever
            // existed), `.deactivating` for the stuck `.disconnecting`,
            // kept honestly: the system still holds a dying session, a
            // flat `.inactive` would only last until the next refresh
            // (the save below broadcasts one itself when it lands) and
            // its flicker would offer a start against a slot that is
            // still occupied. The withdrawal is the intent bookkeeping
            // above; the session's remains are the system's story to
            // finish, and its eventual reading grounds the row through
            // the ordinary observer path.
            tunnel.refreshStatus()
            // One more look after the landing write: the reading can
            // flip in the instant between the peek and the write, and
            // an attempt the system just resolved must not wear the
            // verdict. The bookkeeping above already matches a freshly
            // connected row — flag down, no error — so leaving here is
            // complete, not partial. What does leave with it is the
            // ladder: if the just-raised session dies later, the drop
            // lands in the belt-less non-attempting branch — where the
            // armed rule, untouched here precisely for this, is the
            // designed answer.
            guard tunnel.status == .inactive || tunnel.status == .deactivating else {
                NSLog("[activation] the system answered while \(tunnel.name) was being withdrawn — leaving the session to it")
                return
            }
            tunnel.lastActivationError = .activationUnresolved
            // Sequenced BEFORE the disarm save, deliberately: that save
            // rides the surface this task exists to suspect, and the
            // queue must not wait on it. The hand-off proves the slot
            // free itself — a row still `.deactivating` above keeps
            // the queue parked — and a tunnel it does start issues its
            // own rung-0 sweep, which still sees this row's armed flag
            // (nothing here has touched it yet), so ordering ahead of
            // the disarm cannot let a second armed rule settle.
            self.activateWaitingTunnelIfNeeded()
            // The rule comes down, and this is a decision rather than
            // an omission. `retryLimitReached` keeps its rule because
            // the ladder RAN — every rung answered, and "no network
            // yet" is exactly what on-demand rides out. Here nothing
            // answered at all, which is no evidence of a transient
            // network condition and every sign of a local one, so
            // leaving a connect-on-any-network rule armed would hand
            // the system a tunnel this manager just gave up on.
            //
            // The save rides the gate, which re-reads the liveness
            // bars AT ISSUE — the class-wide closure the old comment
            // here promised to "the cleanup family": the open window
            // is now the landing alone, the narrowest an uncancellable
            // surface allows.
            if case .refused(let disarmError) = await self.guardedStandDown(tunnel, loggingRefusal: false) {
                // The error means the SAVE was refused, not that the
                // rule survived. The helper re-reads the store on a
                // refusal, so the flag usually carries the store's own
                // answer — and when even the re-read fails, the last
                // value known true. Either way it is the truest reading
                // this process has, which is how the line reports it.
                NSLog("[activation] disarm save refused on \(tunnel.name) after an unresolved attempt — armed=\(tunnel.tunnelProvider.isOnDemandEnabled) is the truest reading available: \(disarmError.localizedDescription)")
            }
        }

        // Held so `remove()` can wait for this rung to finish before it
        // deletes anything — see `activationRungTask`. Deliberately NOT
        // self-clearing: a rung can start the next one from inside its
        // own body (the stale-config reload path below), and a `defer`
        // here would run AFTER that assignment and wipe the live
        // handle, leaving `remove()` to await a task that already
        // returned. A finished task answers `.value` instantly, so a
        // stale handle costs nothing; a cleared one costs the wait.
        tunnel.activationRungTask = Task {
            // Pre-flight, first attempt only: when another local
            // user's session holds the system's one VPN slot, fail
            // fast and clean — no enable, no armed recovery rule, no
            // retry ladder. Saving an armed connect-on-any-network
            // rule against an occupied slot is what feeds the
            // cross-user on-demand fight; the honest outcome is the
            // gate's message, not eight doomed attempts. The
            // optimistic `.activating` above keeps the toggle honest
            // while the verdict (two vault reads) is fetched.
            // The verdict rides a tight deadline here: in a vault
            // respawn window the reads hang to their 5s transport
            // timeouts, and rung 0 sitting behind that is pure delay —
            // past the deadline the state is unverifiable, and
            // unverifiable already answers `.free`.
            if retryIndex == 0, case .heldByForeign = await foreignSlotVerdict(within: preflightBudget) {
                guard tunnel.activationAttemptId == attemptId,
                      tunnel.status == .activating else { return }
                tunnel.isAttemptingActivation = false
                tunnel.status = .inactive
                tunnel.lastActivationError = .foreignSlotHolder
                activateWaitingTunnelIfNeeded()
                return
            }
            // Re-guard BOTH facts after the verdict await: the user
            // may have toggled off (or handed the turn to a queued
            // tunnel) while the evidence was fetched. A toggle-off
            // does not touch the attemptId, so status must be checked
            // too — arming and starting past a cancel would raise the
            // tunnel against an explicit stop and persist an armed
            // rule the user just withdrew.
            guard tunnel.activationAttemptId == attemptId,
                  tunnel.status == .activating || tunnel.status == .reasserting else { return }

            // Enable the manager and arm recovery in the same save. An
            // activated tunnel is one the user wants back: the system
            // restarts it whenever a network returns — across reboots
            // and app termination included.
            tunnel.tunnelProvider.isEnabled = true
            Self.armRecovery(on: tunnel.tunnelProvider)
            do {
                try await tunnel.tunnelProvider.savePreferences()
                // Both facts again, for the reason the pre-flight
                // guard above spells out: this await is the widest window in the
                // rung, and a stop that lands inside it does not touch
                // the attempt id. Checking the id alone here let the
                // start proceed past an explicit cancel — and since
                // `armRecovery` ran just above, the tunnel came up
                // armed against the user's own withdrawal.
                guard tunnel.activationAttemptId == attemptId,
                      tunnel.status == .activating || tunnel.status == .reasserting else { return }
                await self.doStartVPNTunnel(tunnel: tunnel, attemptId: attemptId, retryIndex: retryIndex)
            } catch {
                // Only the attempt that still owns the intent may say
                // how it ended. A save can answer late — after a stop,
                // after a newer start, or after the ceiling withdrew
                // this attempt — and without this the refusal would be
                // stamped on whatever the row is doing by then,
                // grounding a newer activation on an older save's
                // failure.
                //
                // Recovery is deliberately left alone here, and not
                // because the store is known clean — a refused save
                // leaves it unknown, which is the whole reason
                // `standDownRecovery` re-reads rather than guesses. It
                // is left alone because armed-and-inactive is a
                // resting state the app already handles: the next
                // activation's sweep disarms it, a stop disarms it,
                // and a removal disarms it before the entry goes.
                guard tunnel.activationAttemptId == attemptId else { return }
                tunnel.isAttemptingActivation = false
                // Re-derived, not grounded flat, for the watchdog's
                // reason: a `.disconnecting` that landed mid-save means
                // the system still holds a dying session, and a flat
                // `.inactive` would flicker back on the next refresh
                // while offering a start against the slot it still
                // occupies. The ordinary refusal is unchanged — a
                // session that never existed derives `.inactive` —
                // and the guard below owns the pairs where the derive
                // is refused or lands raising.
                tunnel.refreshStatus()
                // And the watchdog's raising-guard, for the same flip
                // plus one more of its own: the observer's `.connected`
                // branch lowers the flag but leaves the attempt id, so
                // a session the STORED rule raised out of band
                // mid-save arrives here fully armed — and a row a
                // spurious ground handed to the queue arrives
                // `.waiting`, which the gate above rightly refused to
                // lower (queue slots are manager-driven whatever the
                // flag says). In both pairs the row has moved past
                // this attempt, and the old save's refusal is not a
                // failure it should wear: the drop belt calls writing
                // one under a green row a lie, and stamping a fresh
                // queue slot would hand its turn away with it.
                guard tunnel.status == .inactive || tunnel.status == .deactivating else {
                    NSLog("[activation] arm save refused on \(tunnel.name) but the row has moved on (status=\(tunnel.status)) — leaving it be")
                    return
                }
                tunnel.lastActivationError = .savingFailed(systemError: error)
                activateWaitingTunnelIfNeeded()
            }
        }
    }

    // Sealed at size for the entrance's reason: the load, the one-shot
    // stale retry, the collision verdicts and the retry timer are one
    // sequence whose ordering is the contract.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func doStartVPNTunnel(tunnel: TunnelContainer, attemptId: String, retryIndex: Int) async {
        do {
            try await tunnel.tunnelProvider.loadPreferences()
        } catch {
            // A config that cannot load fails the same way on every
            // system-initiated retry, so an armed rule here is a loop
            // trap and comes down even for an attempt nobody wants any
            // more. "Nobody" is the limit though: if a NEWER attempt
            // has since been granted, the rule in the store is that
            // attempt's, and disarming it would strip recovery from a
            // tunnel the user is bringing up right now.
            if tunnel.activationAttemptId == attemptId || tunnel.activationAttemptId == nil {
                if let disarmError = await Self.standDownRecovery(on: tunnel.tunnelProvider) {
                    NSLog("[activation] recovery rule stayed armed on \(tunnel.name) after a local give-up — \(disarmError.localizedDescription)")
                }
            }
            // The row and the queue are stricter still: writing them
            // for an attempt the user already withdrew would stamp a
            // red `loadingFailed` on their own stop and hand the queue
            // on a second time. Only the attempt that still owns the
            // intent may say how this ended.
            guard tunnel.activationAttemptId == attemptId else { return }
            tunnel.isAttemptingActivation = false
            tunnel.status = .inactive
            tunnel.lastActivationError = .loadingFailed(systemError: error)
            activateWaitingTunnelIfNeeded()
            return
        }

        // The last gate before the session actually comes up, so it
        // asks both facts like every other post-await guard on this
        // path: a stop inside the reload window must not be answered
        // with a start.
        guard tunnel.activationAttemptId == attemptId,
              tunnel.status == .activating || tunnel.status == .reasserting else { return }

        do {
            try tunnel.tunnelProvider.startTunnel()
        } catch {
            // A stale configuration is documented recovery, not a
            // terminal error: another process touched the entry
            // between our save and start, and the cure is reload +
            // retry. ONE chance per ladder, on the first rung only —
            // a config that is stale again after a reload is not
            // raced, it is broken, and it falls to the terminal path
            // below (which stands recovery down), so the ladder can
            // never loop re-arming a persistently stale entry.
            if retryIndex == 0,
               (error as? NEVPNError)?.code == .configurationStale,
               tunnel.activationAttemptId == attemptId,
               (try? await tunnel.tunnelProvider.loadPreferences()) != nil {
                // Re-guard after the reload roundtrip: a toggle-off or
                // a queued handoff during the await must win.
                guard tunnel.activationAttemptId == attemptId,
                      tunnel.status == .activating || tunnel.status == .reasserting else { return }
                startActivation(of: tunnel, at: retryIndex + 1)
                return
            }
            // Collision beats the generic story: `.configurationDisabled`
            // (and some plain start failures) are how an occupied slot
            // surfaces — when the classifier proves a foreign holder,
            // name it instead of printing the system's opaque line.
            // One re-guard after the verdict await covers both exits:
            // a user who cancelled mid-fetch keeps their cancel.
            //
            // Budgeted for the same two reasons the pre-flight is: the
            // row still reads `.activating` with a user behind it, and
            // fail-open converges — BOTH exits below stand the rule
            // down, so a verdict that never arrives costs only the
            // label, never the disarm. Unbounded, this await could
            // outlive the watchdog's ceiling, and the withdrawal would
            // then file "the system never reported why" over a start
            // error the system had in fact thrown.
            let verdict = await foreignSlotVerdict(within: preflightBudget)
            guard tunnel.activationAttemptId == attemptId,
                  tunnel.status == .activating || tunnel.status == .reasserting else { return }
            if case .heldByForeign = verdict {
                tunnel.isAttemptingActivation = false
                tunnel.status = .inactive
                tunnel.lastActivationError = .foreignSlotHolder
                if let disarmError = await Self.standDownRecovery(on: tunnel.tunnelProvider) {
                    NSLog("[activation] recovery rule stayed armed on \(tunnel.name) after a proven foreign holder — \(disarmError.localizedDescription)")
                }
                activateWaitingTunnelIfNeeded()
                return
            }
            tunnel.isAttemptingActivation = false
            tunnel.status = .inactive
            tunnel.lastActivationError = .startingFailed(systemError: error)
            // Local failure — stand recovery down so the OS does not
            // keep relaunching a tunnel whose start throws.
            if let disarmError = await Self.standDownRecovery(on: tunnel.tunnelProvider) {
                NSLog("[activation] recovery rule stayed armed on \(tunnel.name) after a local give-up — \(disarmError.localizedDescription)")
            }
            activateWaitingTunnelIfNeeded()
            return
        }

        // Retry task — if still activating after interval, retry
        tunnel.activationTask?.cancel()
        let tunnelId = tunnel.id
        tunnel.activationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.retryInterval ?? 5.0))
            } catch {
                return
            }
            guard let self,
                  let tunnel = self.tunnels.first(where: { $0.id == tunnelId }),
                  tunnel.activationAttemptId == attemptId else { return }
            if tunnel.status == .activating || tunnel.status == .reasserting {
                self.startActivation(of: tunnel, at: retryIndex + 1)
            }
        }
    }

    /// The stop itself. `startDeactivation` owns the intent
    /// withdrawal and has already done it synchronously, so nothing
    /// here writes the activation bookkeeping: repeating it looked
    /// harmless until you follow the armed path, where this runs a
    /// round-trip later and would erase the ledger of whatever
    /// activation the user started in the meantime. The caller proves
    /// the withdrawal still stands before it gets here.
    func performDeactivation(of tunnel: TunnelContainer) {

        // The stop always goes out. An earlier version skipped it when
        // the provider looked idle, which reads well until you notice
        // where this runs on the armed path: immediately after a
        // `savePreferences` round-trip, exactly when NE can still
        // answer `.invalid` for a session that is very much alive.
        // Skipping there would have painted the row off while the utun
        // kept carrying traffic, with nothing left in the app to stop
        // it. Stopping a session that is already down costs a no-op.
        tunnel.tunnelProvider.stopTunnel()

        // Only the STATUS depends on that reading, and only because a
        // stop sent to a session the system never brought up draws no
        // callback: the row would sit in `.deactivating` for ever. The
        // `.waiting` case is caught upstream; this is its twin for an
        // attempt that dropped before it ever became a session, which
        // the suite's logs show as an `.inactive → .deactivating`
        // transition with nothing after it. A wrong guess here is
        // self-correcting — the observer owns the row from the next
        // notification on — where a wrong guess about the stop was not.
        switch tunnel.tunnelProvider.connectionStatus {
        case .disconnected:
            tunnel.status = .inactive
            // The hand-off, for the reason every other callback-less
            // exit on this path makes it: with no status change
            // coming, a tunnel queued behind this one would wait for
            // its turn until the app restarted. It rides `.disconnected`
            // and NOT `.invalid`, even though both mean "no callback":
            // `.invalid` is also what a manager answers in the moment
            // after a save, for a session that is very much alive.
            // Painting the row there is recoverable, but starting the
            // queued tunnel on top of a session still going down is
            // not — that is two tunnels racing for the one slot.
            activateWaitingTunnelIfNeeded()
        case .invalid:
            tunnel.status = .inactive
        default:
            tunnel.status = .deactivating
        }
    }

    /// Gives the queued tunnel its turn, if there is one and the slot
    /// is actually free.
    ///
    /// Two preconditions, both of them tested here rather than assumed
    /// of the callers, because this method enters
    /// `startActivation(of:at:)` directly and so skips the activation
    /// door that scans for a live session (`beginActivation`).
    ///
    /// The queued container must still be listed. `ingest` rebuilds
    /// `tunnels` and can drop a row without touching this slot, and
    /// starting a tunnel the list no longer holds would raise a session
    /// nothing in the app is tracking. A slot whose tunnel is gone is
    /// stale by definition, so it goes with it.
    ///
    /// And the system's one slot must be free. What every caller did
    /// before this test existed was ground ITS OWN tunnel first, which
    /// is a weaker thing than proving the slot free — the observer's
    /// non-attempting branch grounds whichever tunnel the notification
    /// named, and says nothing about the rest of the list. The removal
    /// and the reload made the difference visible rather than created
    /// it: they run for an arbitrary tunnel and carry no information at
    /// all about who holds the session. Starting a queued tunnel on top
    /// of a live one is exactly the move `performDeactivation` refuses.
    ///
    /// A busy slot KEEPS the queue: the slot stays set so the next
    /// hand-off, once the live session ends, still finds it.
    func activateWaitingTunnelIfNeeded() {
        guard let waitingTunnel else { return }
        guard tunnels.contains(where: { $0 === waitingTunnel }) else {
            self.waitingTunnel = nil
            return
        }
        guard !tunnels.contains(where: {
            $0.id != waitingTunnel.id && $0.status != .inactive && $0.status != .waiting
        }) else { return }
        self.waitingTunnel = nil
        guard waitingTunnel.status == .waiting else { return }
        startActivation(of: waitingTunnel, at: 0)
    }

    // MARK: - Reset (Layer-Level)

    /// Ask the extension to restart its tunnel layer (wstunnel +
    /// WireGuard in ghost mode, WireGuard alone in standalone) in
    /// place — the `utun` interface and its routes stay up, so
    /// nothing leaks out onto the physical NIC while the layer is
    /// rebuilt. Triggered by the user's "Reset Connection" button
    /// when the tunnel appears stuck.
    ///
    /// Extension uses opcode `3`; the handler replies only after the
    /// full stop/start sequence completes, so this wrapper returning
    /// means the layer has been rebuilt (the WireGuard handshake
    /// itself may still be settling).
    func resetConnection(of tunnel: TunnelContainer) async throws {
        guard tunnel.status == .active || tunnel.status == .reasserting else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try tunnel.tunnelProvider.sendProviderMessage(Data([3])) { _ in
                    continuation.resume()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
