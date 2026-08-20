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
                withdrawQueueSlot(previousWaiting)
            }
            tunnel.status = .waiting
            waitingTunnel = tunnel
            startDeactivation(of: activeTunnel)
            // The occupant may have been gone already — an evicted slot
            // whose row the system had grounded, or a session that
            // ended between the scan above and this line — and then the
            // stop above is a no-op with no status change behind it,
            // leaving the tunnel just parked with nothing to start it.
            // The hand-off tests the slot itself, so it starts the
            // queued row only if the slot really is free.
            activateWaitingTunnelIfNeeded()
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
            withdrawQueueSlot(tunnel)
            return
        }

        // Stand the recovery rule down first — with it armed, the
        // system would reconnect the moment the tunnel drops.
        if tunnel.isActivateOnDemandEnabled {
            // Raised HERE, synchronously, rather than inside the task:
            // the interface must have something to show from the tap
            // itself, and a task body starts a scheduling hop later.
            tunnel.pendingDisarmCount += 1
            let disarm = Task {
                // Lowered by `defer` rather than at each exit. This
                // branch has three — barred, a newer intent outranking
                // this stop, and the ordinary one, which a refused save
                // also takes after writing its caption — and two of them
                // are bare `return`s written years apart. A count left
                // standing at any one of them
                // would leave the row saying it is stopping forever,
                // and `defer` is the only shape that also answers the
                // fifth exit somebody adds later.
                defer { tunnel.pendingDisarmCount -= 1 }
                // The gate carries the liveness bars, read when the
                // save RUNS — which answers every stop that is not part
                // of a deletion. The delete flow itself is answered by
                // the parking above rather than by these bars: it
                // issues the stop BEFORE the removal raises its bar, so
                // the bars would find nothing, and `remove()` waits the
                // parked chain out instead. Both halves matter, because
                // the cost of losing that race is a re-minted entry the
                // app can no longer see or delete.
                let outcome = await guardedStandDown(tunnel, loggingRefusal: false)
                if case .barred = outcome { return }
                // A newer intent may have been granted while that save
                // was in flight — the user changed their mind twice.
                // The withdrawal above set the attempt id to nil, so
                // anything else there is a start that outranks this
                // stop, and finishing it would tear down the session
                // that start is bringing up.
                guard tunnel.activationAttemptId == nil else { return }
                if case .done = outcome {
                    // An earlier stop may have left its own refusal on
                    // the row; this one got the rule down, so the
                    // sentence describing a rule that could not be
                    // stood down is no longer about anything.
                    tunnel.clearStopRefusalOnceDisarmed()
                }
                if case .refused(let disarmError) = outcome {
                    // Two facts to report, and both go out: the rule
                    // could not be stood down (so the system may
                    // reconnect this tunnel on its own), and the stop
                    // the user asked for still happens. Returning here
                    // instead — the previous shape — left the session
                    // running with its ladder already dismantled, so
                    // the tunnel could no longer be stopped at all.
                    //
                    // Its own case, not `savingFailed`: nothing here
                    // was being configured, and the sentence the user
                    // reads has to name the rule and the revival it
                    // warns about, because it is the only thing that
                    // will still be on screen when the revival comes.
                    tunnel.lastActivationError = .stopDisarmRefused(systemError: disarmError)
                }
                performDeactivation(of: tunnel)
            }
            park(disarm, on: tunnel)
        } else {
            // The flag is what THIS PROCESS last wrote, and the branch
            // above is where it goes wrong: a disarm save that never
            // answers leaves the flag down over a rule the store still
            // holds. Every stop after that reads the same false flag,
            // takes this branch, and stops a session the system then
            // brings straight back — with nothing anywhere to say why,
            // and no way out from inside the app. So the rule is stood
            // down here too, unconditionally, through the same gate
            // every other deferred disarm uses.
            //
            // Ordered the opposite way from the armed branch, and both
            // orders are deliberate. There the store is KNOWN armed, so
            // the disarm must land before the session drops or the rule
            // revives it — the stop pays a save's wait for that. Here
            // the flag says there is nothing to wait for, and the state
            // that proves it wrong is the state where waiting is worst:
            // the save that lies about is a save that HUNG, so a stop
            // sequenced behind it would never go out at all. The stop
            // goes first, and the revive it may invite is answered
            // below rather than prevented — one bounce, bounded by the
            // save, instead of a stop that never happens.
            //
            // The cost is one save per stop that reaches this branch —
            // an active row whose flag reads disarmed, not the ordinary
            // stop of a running tunnel, which is armed and pays its
            // save above. The cost of reading the flag was a tunnel the
            // user could not turn off.
            performDeactivation(of: tunnel)
            repairRuleAfterStop(tunnel)
        }
    }

    /// The disarmed stop's repair, issued behind the stop it belongs to.
    ///
    /// Split out under its own name rather than inlined: the branch it
    /// serves is a sequence of decisions about a save that has already
    /// been overtaken by the stop, and the entrance above stays a
    /// reviewed narrative about ORDER, not about outcomes.
    private func repairRuleAfterStop(_ tunnel: TunnelContainer) {
        let repair = Task {
            // Only while the withdrawal still stands: a start granted
            // in the meantime owns the rule it just armed, and this
            // save would strip it. Asked twice — once before the save
            // and once after — because the save is where a user's mind
            // changes.
            guard tunnel.activationAttemptId == nil else { return }
            let outcome = await guardedStandDown(tunnel, loggingRefusal: false)
            guard tunnel.activationAttemptId == nil else { return }
            switch outcome {
            case .barred:
                // A removal owns this row now. It stands the rule down
                // itself, sequentially, before the entry goes — on the
                // paths where it gets that far.
                break
            case .refused(let disarmError):
                // Same promise the armed branch makes, and the same
                // case: a rule that could not be cleared is the user's
                // business, because the system may bring this tunnel
                // back on its own. Written only onto a row that is
                // down, like every other error on this path: a session
                // the system has meanwhile raised wears no red caption
                // for a save that failed under it.
                if tunnel.status == .inactive || tunnel.status == .deactivating {
                    tunnel.lastActivationError = .stopDisarmRefused(systemError: disarmError)
                }
            case .done:
                // An earlier stop may have left its refused-disarm
                // caption on this row; this pass got the rule down, so
                // the sentence warning that the system may bring the
                // tunnel back is no longer about anything. Same call the
                // armed branch makes for the same reason, and its own
                // ledger test keeps a rung's verdict safe.
                tunnel.clearStopRefusalOnceDisarmed()
                // The rule is gone; if it revived the session while the
                // repair was in flight, the user's stop still stands —
                // it was withdrawn before any of this and nothing since
                // has granted a new intent. A revive is most often
                // `.activating`, because it reaches the row as the
                // system's own `.connecting`: an attempt of OURS could
                // never read that way with no id in the ledger, since
                // the rung stamps the id in the same synchronous block
                // that paints the row. `.waiting` is excluded on
                // purpose — a queue park carries no id either, and it
                // is not a session.
                if tunnel.status == .active || tunnel.status == .reasserting
                    || tunnel.status == .activating {
                    performDeactivation(of: tunnel)
                }
            }
        }
        park(repair, on: tunnel)
    }

    /// Parks a stop's disarm where a removal can wait for it, without
    /// putting anything in front of the stop itself.
    ///
    /// The handle has to cover EVERY disarm still in flight, because a
    /// removal waits on one handle and a stop can be issued twice — the
    /// toggle still reads ON while a disarm save is in flight, and
    /// switching tunnels issues a second stop on its own. An
    /// overwritten handle is a save nobody can wait for, and it lands
    /// after the entry is gone.
    ///
    /// So the JOIN is chained, never the work. The disarm task itself
    /// was started by the caller and is already running: putting the
    /// previous one in front of it would sequence a user's stop behind
    /// a save that may hang, and the second tap on a wedged stop —
    /// documented as the way out of exactly that state — would stop
    /// answering. This task waits for both and does nothing else.
    private func park(_ disarm: Task<Void, Never>, on tunnel: TunnelContainer) {
        let previous = tunnel.pendingDisarmTask
        tunnel.pendingDisarmTask = Task {
            await previous?.value
            await disarm.value
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
        // No ARMED FILTER: a tunnel whose flag reads false may still
        // hold the rule in the store from an earlier refused save, and
        // the sweep is the last chance to clear it before the
        // extensions go. That exemption is about the flag, and only
        // about the flag.
        //
        // The LIVENESS bars still apply, and this sweep is the writer
        // that needs them most. A save is a write to the system store,
        // and a save landing on a row whose entry a removal has already
        // taken RE-MINTS that entry. The entry-first order makes the
        // window wide and certain rather than narrow and unlucky:
        // `remove()` takes the entry, then spends a retry ladder on the
        // payload, and deliberately keeps the row in the list for that
        // whole stretch — while the uninstall latch this flow raised
        // stops any reload from pruning the mirror. So the row is still
        // here to be iterated, and writing to it hands the teardown an
        // entry with no payload: invisible behind the ownership
        // boundary, undeletable from the app, and left behind if the
        // teardown then throws before its removal step.
        //
        // What the skip costs, counted rather than waved away. USUALLY
        // nothing: `remove()` stands that row's rule down itself, in
        // sequence, before it touches the entry. FOUR of its exits
        // return before reaching that step — a rung wait that times
        // out, a vault that will not say what it holds, the custody
        // order's own payload delete failing, and a second press, which
        // is harmless because the removal that owns the bar is still
        // walking toward the stand-down.
        //
        // Three of those leave a rule the teardown then takes away with
        // the entry, so the residue dies with it. The fourth does not,
        // and it is named here rather than smoothed over: a CUSTODY row
        // whose payload delete is refused keeps BOTH halves, and this
        // teardown deliberately leaves such an entry in place — its
        // entry is the only anchor an unreadable payload has. So that
        // one entry can outlive the uninstall still carrying its rule,
        // and a reinstall brings the extensions back to honour it.
        //
        // The bar is still right, and the asymmetry is the reason: the
        // residue it PREVENTS is a re-minted entry with no payload —
        // invisible, undeletable, permanent. The residue it leaves is
        // an armed rule on a row the user can still see and delete. One
        // of those the user can act on. Both are logged.
        //
        // The membership half of the bar is not redundant either: the
        // array is snapshotted at the loop head and every iteration
        // suspends, so a row can leave the list underneath it.
        for tunnel in tunnels {
            guard mayWriteStore(tunnel) else {
                NSLog("[uninstall] recovery sweep skipped \(tunnel.name): it is being removed, or the list no longer holds it")
                continue
            }
            // Best-effort, but not blind: a rule that survives its
            // save is exactly what this sweep exists to prevent, and
            // the uninstall continues either way — so it gets said out
            // loud rather than swallowed by a `try?`.
            if let error = await Self.standDownRecovery(on: tunnel.tunnelProvider) {
                NSLog("[uninstall] disarm save refused on \(tunnel.name) — armed=\(tunnel.tunnelProvider.isOnDemandEnabled) is the truest reading available: \(error.localizedDescription)")
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
    /// Returns nil when the rule is down for real. Every caller that
    /// HAS a container arrives through `guardedStandDown` or the exempt
    /// list it names: the connection gate's engage sweep was the last
    /// hand-made one and goes through `standDownForSlotGate` today.
    ///
    /// One caller does not have a container and calls here directly —
    /// that same gate, on the path where no manager has been PUBLISHED
    /// yet. It is unbarred and entitled to be, and the entitlement is
    /// about REMOVALS rather than existence: a manager object can exist
    /// mid-creation with a fully materialized list, since the loader
    /// reconciles before it publishes, but until it is published no
    /// view holds it and no `remove()` can have been issued through it
    /// — so the bars this write is missing would refuse nothing. That
    /// is the ordinary case on a launch where a foreign session already
    /// holds the slot, since the view that builds the manager renders
    /// only once the gate reports the slot free — so this is a live
    /// path, not a theoretical one, and the gate's own site carries the
    /// same argument in the same words.
    ///
    /// One thing that sweep still does is SELECT by the flag, and it is
    /// the only caller that may: rung 0 dropped its flag filter because
    /// a rule the store holds under a disarmed flag is exactly what it
    /// existed to clear, whereas the gate's filter is what stops its own
    /// pass from re-triggering itself through the configuration-change
    /// notification. Same-looking line, opposite reason — see the
    /// sweep's own doc before making them agree.
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

    /// The connection gate's way through `guardedStandDown`.
    ///
    /// The gate stands our armed rules down when another local user's
    /// session holds the system's one VPN slot, and it does that from
    /// providers it loaded ITSELF — different objects from the ones this
    /// manager's containers wrap, describing the same configurations. So
    /// the gate has nothing to hand `guardedStandDown`, which takes a
    /// container: one of that gate's two bars is an identity test, and
    /// identity can never match across two system reads. (The other bar
    /// is by id and would have been reachable — it is the pair that
    /// needs a row of this manager's own, not each bar separately.)
    ///
    /// It asks by ID instead, and the write then goes through the
    /// manager's own provider rather than the gate's copy. Two things
    /// come out of that. The bars apply — a stand-down landing on an
    /// entry a removal has just taken would re-mint it, which is the
    /// hidden-entry class this campaign exists to close, and the gate
    /// engages exactly when a user might be deleting a tunnel that will
    /// not connect. And the manager's own projection stops diverging
    /// from what was written, which the gate's copy could never fix.
    ///
    /// An id the list does not hold is BARRED rather than written
    /// through the gate's object, and the reason is what this manager
    /// can VOUCH for rather than what the system has. Absence from the
    /// list does not prove the entry is gone: an ingest also drops a row
    /// it cannot attribute, which is what a dark vault produces for
    /// every row at once. What absence does establish is that no
    /// container here backs this id, so a save issued for it is either
    /// writing for nobody or minting an entry the list will not show —
    /// and the cost of refusing is one pass, since the gate re-checks
    /// every few seconds and a row that returns is picked up then.
    func standDownForSlotGate(id: UUID, context: @autoclosure () -> String) async -> StandDownOutcome {
        guard let tunnel = tunnels.first(where: { $0.id == id }) else { return .barred }
        return await guardedStandDown(tunnel, context: context())
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
    /// The connection gate reaches this through
    /// `standDownForSlotGate(id:context:)` rather than directly,
    /// because its providers come from its own system read and object
    /// identity cannot match across two reads — see that method for why
    /// an id it cannot find is barred rather than written.
    ///
    /// Exempt by contract, not by oversight: the rung's own inline
    /// give-up disarms (a `remove()` WAITS the rung out before
    /// deleting, so an in-rung save cannot race a completed removal)
    /// `disarmAllRecovery` (exempt from the ARMED FILTER only — the
    /// uninstall sweep is the last chance to clear a rule whose flag
    /// lies, but it reads `mayWriteStore` like every other deferred
    /// writer, because a save landing on a row whose entry a removal
    /// has taken re-mints that entry), and
    /// `remove()`'s own sequenced disarm — it runs under its own
    /// `removingIds` entry, so routing it here would only bar itself.
    ///
    /// Refusals log in the standard format unless the caller carries
    /// its own reporting surface — both halves of the stop write
    /// `stopDisarmRefused`, which reaches the user rather than the log.
    ///
    /// The deferred disarms that could escape these bars are waited out
    /// instead: on the delete path a stop's task is enqueued BEFORE
    /// `remove()` raises its bar, so the bars would find nothing to bar
    /// — those tasks are therefore parked on the container as a CHAIN
    /// (`pendingDisarmTask`, each awaiting the one it supersedes) and
    /// `remove()` waits the chain out in the same bounded window it
    /// waits the rung.
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
            // What is reported is the SAVE's refusal and the truest
            // reading available after it — never "the rule stayed
            // armed", which this refusal does not establish: the
            // helper re-read the store on its way out, and callers now
            // include a sweep that disarms rows which were never armed
            // in the first place. The sentence itself lives in one
            // place, so the in-rung helper cannot drift from it.
            Self.logDisarmRefusal(on: tunnel, context(), error)
        }
        return .refused(error)
    }

    /// A give-up exit's ground, DERIVED rather than declared.
    ///
    /// Every caller here has just lowered the attempt flag, which opens
    /// the status gate, so the row can take the system's own reading
    /// instead of the `.inactive` this code used to guess. The
    /// difference is not cosmetic: a flat `.inactive` written over a
    /// session the system still holds is a lie that survives until the
    /// next refresh, and while it stands the interface offers a start
    /// against a slot that is occupied. The watchdog has always
    /// re-derived; this is the same move for the exits that had not.
    ///
    /// Synchronous by contract — no task, no await. Four of the five
    /// callers run inside the rung, where the rung-wait is what makes
    /// their disarms exempt from the deferred-save gate; a helper that
    /// suspended would take that exemption away with it. (The fifth,
    /// the exhausted ladder, is reached from the retry timer and
    /// disarms nothing at all — a timeout keeps its rule on purpose.)
    ///
    /// What counts as "the system disagrees" is narrower than "the
    /// system is saying something", and the difference is the whole
    /// correctness of this helper. A row reading `.activating` means
    /// the system is still CONNECTING — which is not a session it
    /// holds, it is the very attempt this exit has just abandoned, and
    /// the ladder's exhaustion is precisely its explanation. Bailing
    /// there would leave the timeout unexplained for ever: nothing is
    /// scheduled behind a spent ladder, the watchdog is already
    /// disqualified by the lowered flag, and the row would spin until
    /// the system happened to speak. So `.activating` is grounded here
    /// rather than deferred to.
    ///
    /// Answers false only when the row belongs to somebody else: an
    /// ESTABLISHED session (`.active`, `.reasserting`) that the system
    /// raised while this exit was deciding, or a `.waiting` slot the
    /// queue has since taken. Then the caller writes nothing at all —
    /// a row that is not this give-up's to explain must not wear its
    /// verdict, and the hand-off would be starting a second tunnel
    /// over a live one.
    private func groundedAfterGiveUp(_ tunnel: TunnelContainer,
                                     _ reason: @autoclosure () -> String) -> Bool {
        tunnel.refreshStatus()
        switch tunnel.status {
        case .active, .reasserting:
            NSLog("[activation] the system answered while \(tunnel.name) was giving up (\(reason())) — leaving the session to it")
            return false
        case .waiting:
            NSLog("[activation] the queue took \(tunnel.name) while it was giving up (\(reason())) — leaving the row to its slot")
            return false
        case .activating:
            // Our own pending start, and nothing is left to advance it.
            tunnel.status = .inactive
            return true
        case .inactive, .deactivating:
            // `.deactivating` stays: the system holds a dying session
            // and its remains are the system's story to finish.
            return true
        }
    }

    /// The give-up disarm, reported honestly.
    ///
    /// A refused save does not prove the rule survived: the helper
    /// re-reads the store on its way out, so what this line carries is
    /// the refusal and the truest reading left after it — the same
    /// sentence the deferred-save gate prints for the sites it covers.
    /// In-rung by design, which is why it does not ride that gate:
    /// `remove()` waits the rung out before it deletes anything.
    private static func standDownAfterGiveUp(_ tunnel: TunnelContainer, _ context: String) async {
        guard let error = await standDownRecovery(on: tunnel.tunnelProvider) else { return }
        logDisarmRefusal(on: tunnel, context, error)
    }

    /// The one sentence a refused disarm gets on the activation paths.
    ///
    /// Written once and called from both the deferred-save gate and the
    /// in-rung helper, because two copies of a line that must say the
    /// same thing is how they start saying different ones — the exact
    /// reason the watchdog stopped keeping its own. Two older lines
    /// still say it their own way: the
    /// uninstall sweep's line and `remove()`'s, which used to read
    /// "survived the sweep" and "recovery rule stayed armed" and now
    /// say what this one says. Neither refusal establishes what
    /// it claims, and both belong to the passes that own those paths.
    private static func logDisarmRefusal(on tunnel: TunnelContainer, _ context: String, _ error: Error) {
        let suffix = context.isEmpty ? "" : " \(context)"
        NSLog("[activation] disarm save refused on \(tunnel.name)\(suffix) — armed=\(tunnel.tunnelProvider.isOnDemandEnabled) is the truest reading available: \(error.localizedDescription)")
    }

    /// Takes a row out of the queue — the slot AND the ledger.
    ///
    /// They go together because a row can arrive here still carrying an
    /// attempt id, and a slot cleared without the ledger leaves
    /// bookkeeping nothing will ever answer: a belt or a rung still in
    /// flight would match that id and write for an attempt nobody is
    /// waiting on. Clearing it makes them find a mismatch and fall
    /// silent, which is the honest outcome at BOTH call sites — each is
    /// the user withdrawing the intent (a newer start evicting this
    /// slot, or a stop), and the user's own action is the explanation.
    /// The ledger is taken unconditionally for the same reason the
    /// task is cancelled: a live `activationTask` would climb a fresh
    /// rung for an intent that no longer exists.
    ///
    /// Only the PAINT is conditional. A parked row can be raised out of
    /// its slot behind our back — the status gate refuses lowering
    /// values on a `.waiting` row but lets a rising one land, and both
    /// the reload and the observer's non-attempting branch do exactly
    /// that — and writing `.inactive` over a row that is carrying
    /// traffic would take it off the screen while it runs, and make the
    /// stop that follows return early on its own `.inactive` guard. So
    /// the row is only grounded while it really is parked; for that row
    /// the flat write is mechanical rather than a choice, since
    /// `.waiting` is unconditionally manager-driven and a re-derive
    /// could never lower it.
    private func withdrawQueueSlot(_ tunnel: TunnelContainer) {
        if waitingTunnel?.id == tunnel.id { waitingTunnel = nil }
        tunnel.isAttemptingActivation = false
        tunnel.activationAttemptId = nil
        tunnel.activationTask?.cancel()
        tunnel.activationTask = nil
        guard tunnel.status == .waiting else {
            // The row left its slot on the system's own initiative, and
            // the ledger above has just taken away the last thing that
            // could have resolved it — with no attempt id the ceiling's
            // watchdog is disqualified, and there is no rung behind it.
            // So it is handed back to the system's own reading rather
            // than abandoned: whatever the session is doing, the row
            // says it. (The gate is open here, because the flag came
            // down two lines up.)
            tunnel.refreshStatus()
            return
        }
        tunnel.status = .inactive
    }

    /// The same two liveness bars, for a deferred write that is NOT a
    /// disarm.
    ///
    /// `guardedStandDown` carries them for the disarm family, and it
    /// cannot serve the other one: the projection realign writes an
    /// IDENTITY, so routing it through a helper whose job is to stand a
    /// rule down would either disarm a row that is only being renamed
    /// or strip the gate of the meaning it was built with. What both
    /// families share is the question — may this suspended writer still
    /// touch the system store for this row — and that question lives
    /// here, once, so a third deferred writer has somewhere to ask it.
    func mayWriteStore(_ tunnel: TunnelContainer) -> Bool {
        !removingIds.contains(tunnel.id) && tunnels.contains(where: { $0 === tunnel })
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
            // The token goes with the intent. Left behind, it is an id
            // nothing will ever answer — and a late belt or rung that
            // still matches it would write for an attempt this exit has
            // just closed.
            tunnel.activationAttemptId = nil
            tunnel.activationTask?.cancel()
            tunnel.activationTask = nil
            guard groundedAfterGiveUp(tunnel, "the ladder ran out") else { return }
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
            // names the tunnel whose disarm save was refused together
            // with the truest reading left after it — never that the
            // rule survived, which a refusal does not establish.
            //
            // Unconditional, no armed-filter, for the reason
            // `standDownRecovery` states about itself: the flag is
            // this process's answer, not the store's, and a save that
            // was refused — or that hung and never answered — leaves
            // the two disagreeing, flag down over a rule still in the
            // store. Reading the flag here made this the one sweep
            // that skipped precisely the tunnel it exists to find, and
            // the invariant it serves (Armed<=1) was then counted from
            // the same lying flag. The uninstall sweep already made
            // this choice and says so. What it costs is one save per
            // other tunnel per activation; what filtering cost was a
            // second armed rule nobody could see.
            for other in tunnels where other.id != tunnel.id {
                Task {
                    // Liveness reads at RUN time, and both bars, live
                    // inside the gate — the site cannot forget them.
                    // Held strongly, and there is no weaker option that
                    // would help: the call itself is on the manager, so
                    // a save that hangs pins it either way. What this
                    // loop costs is one such task per OTHER tunnel per
                    // activation.
                    await guardedStandDown(other, context: "during another tunnel's rung 0")
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
            // a save. A row that is `.active` or parked `.waiting` is
            // not an unresolved attempt: the first resolved, and the
            // second belongs to the queue.
            //
            // `.inactive` is admitted, and it is the correction that
            // matters most here: the ledger above — this attempt id,
            // the flag still up, no error — is what says an attempt is
            // live, and NO path that resolves one leaves it intact.
            // Every give-up exit lowers the attempt flag BEFORE it
            // grounds the row (the error follows synchronously, in the
            // same block, and one exit deliberately writes none at
            // all), the stop withdraws the ledger synchronously, and
            // the observer's own drop branch lowers the flag too. The
            // flag is the load-bearing half: an exit that grounded the
            // row first and lowered the ledger after an await would
            // carry this exact shape across the suspension and earn
            // itself a withdrawal. The queue's own eviction takes the
            // ledger with it now, so an evicted row never reaches this
            // guard at all — its attempt id is gone and the first
            // condition closes. What is left is the case this guard used to
            // read as "resolved": a system reading that grounded the
            // row under a live attempt — a refresh landing while the
            // row sat `.deactivating`, whose notification never came —
            // after which the watchdog withdrew from the one attempt
            // nobody else was going to finish. Silence, no error, and
            // an armed rule left standing on a tunnel this manager had
            // given up on.
            guard let self,
                  tunnel.activationAttemptId == attemptId,
                  tunnel.isAttemptingActivation,
                  tunnel.lastActivationError == nil,
                  tunnel.status == .activating || tunnel.status == .reasserting
                    || tunnel.status == .deactivating || tunnel.status == .inactive,
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
            // existed) and for the row a refresh already grounded,
            // where it is a no-op that keeps one shape for all three
            // causes, `.deactivating` for the stuck `.disconnecting`,
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
            // own rung-0 sweep, which covers this row whatever its flag
            // reads by then, so ordering ahead of the disarm cannot let
            // a second armed rule settle.
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
            //
            // The refusal is reported by the gate rather than here. A
            // refused save does not mean the rule survived — the helper
            // re-reads the store on its way out, so the flag carries
            // the store's own answer, or the last value known true when
            // even the re-read failed — and that is precisely the
            // sentence the gate prints, context and all. Keeping a copy
            // of it here is how two lines that must say the same thing
            // start saying different ones.
            await self.guardedStandDown(tunnel, context: "after an unresolved attempt")
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
                // Everything the user can see is written first and
                // synchronously — the row, the verdict, the queue's
                // turn — because the save below has no deadline and the
                // window it opens is one where the flag is already
                // down: the watchdog is disqualified, the status gate
                // is open, and a refresh landing inside it would ground
                // this row without a word.
                if groundedAfterGiveUp(tunnel, "a proven foreign holder") {
                    tunnel.lastActivationError = .foreignSlotHolder
                    activateWaitingTunnelIfNeeded()
                }
                // The rule comes down whatever the row ended up
                // reading, because the evidence is about the SLOT, not
                // about us: a proven foreign holder makes our
                // connect-on-any-network rule the fuel of the
                // cross-user fight. This was the one collision exit
                // that left it armed. In-rung, like its siblings.
                await Self.standDownAfterGiveUp(tunnel, "at the rung-0 pre-flight, after a proven foreign holder")
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
                await Self.standDownAfterGiveUp(tunnel, "after a configuration that would not load")
            }
            // The row and the queue are stricter still: writing them
            // for an attempt the user already withdrew would stamp a
            // red `loadingFailed` on their own stop and hand the queue
            // on a second time. Only the attempt that still owns the
            // intent may say how this ended.
            guard tunnel.activationAttemptId == attemptId else { return }
            tunnel.isAttemptingActivation = false
            guard groundedAfterGiveUp(tunnel, "a configuration that would not load") else { return }
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
                // User-facing writes first and synchronously, disarm
                // after: the queue must not wait on a preference
                // round-trip that may hang. Whoever takes the turn
                // climbs rung 0, whose sweep now covers this row too.
                if groundedAfterGiveUp(tunnel, "a proven foreign holder") {
                    tunnel.lastActivationError = .foreignSlotHolder
                    activateWaitingTunnelIfNeeded()
                }
                // Unconditional, for the pre-flight twin's reason: the
                // proof is about the slot. Even a row the system has
                // meanwhile raised must not keep a rule that was armed
                // against a holder we just proved.
                await Self.standDownAfterGiveUp(tunnel, "in the start-catch, after a proven foreign holder")
                return
            }
            tunnel.isAttemptingActivation = false
            guard groundedAfterGiveUp(tunnel, "a start the system refused") else { return }
            tunnel.lastActivationError = .startingFailed(systemError: error)
            activateWaitingTunnelIfNeeded()
            // Local failure — stand recovery down so the OS does not
            // keep relaunching a tunnel whose start throws. Conditional
            // where the collision arm is not, and the asymmetry is the
            // evidence: a throw says OUR start failed, so a session the
            // system has raised in the meantime disproves it, and
            // stripping that session's rule would be answering an
            // error that no longer describes anything.
            await Self.standDownAfterGiveUp(tunnel, "after a local give-up")
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
    /// Extension uses opcode `3`. The handler replies only after the
    /// full stop/start sequence completes — but "it replied" and "the
    /// layer was rebuilt" are not the same fact, and this doc used to
    /// say they were: *returning means the layer has been rebuilt*.
    /// That held for one of the extension's four exits. The other
    /// three — no live layer to rebuild, wstunnel refusing to restart,
    /// the adapter refusing to restart — also replied, and one of them
    /// logged "Reset complete" doing it. The reply now carries the
    /// outcome as its second byte (`TunnelResetReply`), so WHEN A
    /// RESET WAS ISSUED AND THE EXTENSION NAMED ITS OUTCOME, returning
    /// without throwing means the layer really was rebuilt, and the
    /// three failures each throw. A rebuilt layer still says nothing
    /// about the WireGuard handshake, which may be settling after it.
    ///
    /// That qualification is not decoration — two exits below return
    /// cleanly having established nothing about the layer, and a
    /// caller reading only the sentence above would take both for a
    /// rebuild. There is no live session to reset (the status guard,
    /// which sends no message at all), and the extension answered
    /// without an outcome byte (an older build, whose reply cannot
    /// mean more than it ever did). Neither is a failure; neither is
    /// a rebuild either.
    ///
    /// And the wait is BOUNDED. It was not: a `sendProviderMessage`
    /// whose completion never fires left this continuation suspended
    /// for the life of the process, with the user's Reset button
    /// awaiting it and no error ever reaching the alert. The ceiling
    /// is generous against the work — the suite measures a whole
    /// reset at ~0.2s in both modes — because a slow-but-working
    /// reset reported as a failure would be the worse mistake.
    func resetConnection(of tunnel: TunnelContainer) async throws {
        guard tunnel.status == .active || tunnel.status == .reasserting else { return }

        let outcome: ResetOutcome = await withCheckedContinuation { continuation in
            let resume = SingleResume(continuation)
            do {
                try tunnel.tunnelProvider.sendProviderMessage(Data([3])) { data in
                    resume.finish(.answered(TunnelResetReply.read(data)))
                }
            } catch {
                resume.finish(.sendFailed(error.localizedDescription))
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(Self.resetBudget))
                resume.finish(.unanswered)
            }
        }

        switch outcome {
        case .answered(let reading):
            switch reading {
            case .absent:
                // What every extension before this contract sent, and
                // it meant exactly what this method used to conclude
                // from any reply at all. Reading it as a failure would
                // invent one; see `TunnelResetReply`'s own note.
                return
            case .outcome(let reply):
                if let failure = TunnelManagementError.forReset(reply) { throw failure }
            case .unrecognised(let raw):
                // A byte, just not one of ours. Kept apart from the
                // absent case on purpose: something was reported and
                // this app cannot read it, so it can claim neither a
                // rebuilt layer nor a broken one.
                throw TunnelManagementError.resetOutcomeUnrecognised(raw: raw)
            }
        case .sendFailed(let description):
            throw TunnelManagementError.resetSendFailed(systemError: description)
        case .unanswered:
            throw TunnelManagementError.resetUnanswered
        }
    }

    /// Wall-clock ceiling for a reset round trip, in seconds.
    private nonisolated static let resetBudget: TimeInterval = 10
}

/// What came back from opcode 3, before it is read as success or
/// failure. Silence and a refusal to send stay apart from an answer
/// the whole way, the same way the vault client keeps them apart:
/// only an answer can carry a verdict about the layer.
private enum ResetOutcome: Sendable {
    /// The extension answered. What its bytes amount to is the
    /// `Reading` — an outcome, no outcome byte at all, or one this
    /// build cannot read.
    case answered(TunnelResetReply.Reading)
    /// The message could not be handed to the session at all.
    case sendFailed(String)
    /// Nothing came back inside the budget.
    case unanswered
}
