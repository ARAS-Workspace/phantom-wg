#if DEBUG
import Foundation
import NetworkExtension

/// The activation machinery's interleavings, driven rather than waited
/// for.
///
/// Everything here tests a window a hand cannot AIM at. Two are
/// closed by the interface outright (the Delete button is disabled
/// unless a tunnel is inactive, and a toggle cannot be tapped twice
/// in one runloop turn); the third — a stop landing while the rung's
/// preferences save is in flight — is reachable by hand only by
/// chance, because the save window is invisible. All of them exist in
/// the code, and the system walks into them on its own when an
/// on-demand rule reconnects a tunnel at the wrong moment. A guard
/// against a window nobody can aim at is either proven mechanically
/// or it is decoration.
///
/// Every step runs against a side `TunnelsManager` over synthetic
/// providers: the production type, the production methods, canned NE
/// objects. The real vault answers, so nothing here fakes the parts
/// under test — only the system surface that cannot be scheduled.
final class ActivationSeamWorkflow: TestWorkflow {
    override var displayName: String { "Activation Seam (Driven Interleavings)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Removal Bars A Queued Disarm Save", disarmDuringRemoval),
            WorkflowStep("Belt Files A System Record As The Failure", beltFilesRecord),
            WorkflowStep("Belt Spends The One Revive On A Silent Drop", beltSpendsRevive),
            WorkflowStep("Spent Revive Still Leaves An Error Behind", beltStandInAfterSpentRevive),
            WorkflowStep("Belt Does Not Write Over A Revived Session", beltRespectsRevivedSession),
            WorkflowStep("A Stop Cannot Be Answered With A Start", stopBeatsInFlightSave),
            WorkflowStep("A Refused Disarm Surfaces And The Stop Still Lands", refusedDisarmSurfaces),
            WorkflowStep("A List Refresh Cannot Cancel An Activation", refreshCannotCancelActivation),
            WorkflowStep("A List Refresh Cannot Take A Queued Tunnel's Turn", refreshCannotDropTheQueue),
            WorkflowStep("A Removal Hands The Queue On Only When The Slot Is Free", removalHandsOnTheQueue),
            WorkflowStep("A Queue Slot Whose Tunnel Left The List Is Discarded", staleQueueSlotIsDiscarded),
            WorkflowStep("An Attempt That Never Resolves Is Withdrawn", wedgedAttemptIsWithdrawn),
            WorkflowStep("A Withdrawal Leaves The Dying Session To The System", dyingSessionIsWithdrawnInPlace),
            WorkflowStep("A Grounded Row Cannot Silence Its Own Attempt", groundedRowIsStillWithdrawn),
            WorkflowStep("The Sweep Reaches A Rule The Flag Denies", sweepReachesAStoreOnlyRule),
            WorkflowStep("A Stop Reaches A Rule The Flag Denies", stopReachesAStoreOnlyRule),
            WorkflowStep("A Revived Session Sheds The Failed Attempt's Verdict", revivalClearsTheVerdict),
            WorkflowStep("A Give-Up Does Not Ground A Session The System Holds", giveUpDoesNotGroundALiveSession),
            WorkflowStep("The Watchdog Leaves A Rising Session Alone", peekLeavesARisingSessionAlone),
            WorkflowStep("A Config That Will Not Load Loses Its Rule", loadFailureStandsTheRuleDown),
            WorkflowStep("A Start The System Refuses Loses Its Rule", startFailureStandsTheRuleDown),
            WorkflowStep("A Second Removal Is A Silent No-Op", secondRemovalIsASilentNoOp),
            WorkflowStep("The Delete Flow's Stop Cannot Outrun Its Removal", deleteFlowStopCannotOutrunItsRemoval),
        ]
    }

    // Reachable from the sibling file that carries the
    // rule-ownership steps.
    let runTag = String(UUID().uuidString.prefix(8))

    // MARK: - Shared rig

    /// One driven tunnel on a side manager, brought to the point every
    /// belt scenario starts from: activation issued, `startTunnel`
    /// observed, session never connected. Returns nil (with the step
    /// verdict already recorded) when that point is not reached.
    func activatedRig(
        name: String,
        configure: (FakeSlotProvider) -> Void
    ) async -> (fake: FakeSlotProvider, manager: TunnelsManager, container: TunnelContainer)? {
        let identity = TunnelIdentity(id: UUID(), name: name, createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)
        configure(fake)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize \(name)")
            return nil
        }
        manager.startActivation(of: container)
        // Rung 0 rides a real vault verdict before it starts anything,
        // so the observed start — not a guessed sleep — is the gate.
        let start = Date()
        while Date().timeIntervalSince(start) < 8 {
            if fake.startCount >= 1 { return (fake, manager, container) }
            // A Stop mid-wait leaves without the skip below: the run
            // is ending, and "vault verdict too slow" would name a
            // cause that was never measured.
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        skip("environment: the rig's activation never reached startTunnel (vault verdict too slow?)")
        return nil
    }

    /// Polls until `condition` holds or the budget runs out. Exits on
    /// cancellation with the truth of that moment, the way the
    /// deadline exit does: after a Stop the sleep below throws
    /// immediately and `try?` swallows it, so without the check every
    /// remaining pass would spin the main actor hot for its whole
    /// wall-clock window while the user watches Stop do nothing.
    func settle(within seconds: Double, until condition: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if condition() { return true }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    // MARK: - Steps

    /// The stop-then-delete race, which the app can only enter when a
    /// tunnel comes up between the confirmation dialog opening and the
    /// user confirming.
    ///
    /// `deleteTunnel` calls `startDeactivation` and then `remove()`
    /// without waiting for the first to finish. The stop of an armed
    /// tunnel does its disarm on a queued, actor-inherited task, and a
    /// save landing after `removePreferences` writes the entry back,
    /// armed — whether its payload is still there depends on the order
    /// the removal chose, but the entry comes back either way, behind a
    /// list that no longer holds it.
    ///
    /// The contract as of this session, and what each count proves:
    /// `remove()` stands the rule down ITSELF, sequentially, before it
    /// deletes the entry — so exactly ONE save belongs to the removal.
    /// The queued stop-disarm is barred by `removingIds` and must
    /// contribute nothing: a second save would be that bar failing.
    /// (The first version of this step asserted ZERO saves and went
    /// red the moment remove() gained its own stand-down — the guard
    /// caught the intentional contract change, which is its job; the
    /// assertion now names the contract instead of the old shape.)
    ///
    /// Driven by holding the removal open: the fake's
    /// `removePreferences` answers slowly, and the stop is issued
    /// inside that window.
    private func disarmDuringRemoval() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Remove-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .connected)
        fake.isEnabled = true
        fake.arrangeArmed()                // armed: the stop takes the disarm path
        fake.removeAnswer = .succeedsAfter(seconds: 3)

        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the seam tunnel")
            return
        }

        let savesBefore = fake.saveCount
        let removal = Task { @MainActor in
            (try? await manager.remove(tunnel: container)) != nil
        }

        // Wait for the removal to actually be in flight. Reading the
        // bar rather than sleeping a guessed interval: the window
        // opens when the id is listed, not when a timer says so.
        var barred = false
        let start = Date()
        while Date().timeIntervalSince(start) < 5 {
            if manager.removingIds.contains(identity.id) { barred = true; break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard barred else {
            _ = await removal.value
            skip("environment: removal never reached its in-flight window")
            return
        }

        // The stop the user's delete would have issued, now landing
        // squarely inside the removal.
        manager.startDeactivation(of: container)

        // Give the queued disarm task every chance to misbehave: it
        // runs on the next main-actor turn, well inside the 3s the
        // removal is holding open.
        try? await Task.sleep(for: .milliseconds(600))
        check(fake.saveCount - savesBefore <= 1,
              "at most the removal's own stand-down has written (saves \(savesBefore) → \(fake.saveCount))")
        // Read while the entry is still there. The removal answers
        // slowly on purpose, and a removed entry takes its stored rule
        // with it — so after the entry goes, a cleared store proves
        // nothing about who cleared it. Here it can only be the
        // stand-down, which is the ordering this step exists to pin.
        //
        // Waited for rather than assumed inside the sleep above: the
        // removal reaches its stand-down only after the vault has been
        // asked what it holds — with the same three attempts a delete
        // spends — and a slow vault would otherwise turn "not yet" into
        // a verdict about the product.
        guard await settle(within: 3, until: { fake.saveCount > savesBefore }) else {
            _ = await removal.value
            skip("environment: the removal never reached its own stand-down (vault slow?)")
            return
        }
        check(!fake.storedOnDemand,
              "the rule left the STORE before the entry did — the stand-down landed first (store=\(fake.storedOnDemand), removes=\(fake.removeCount))")

        guard await removal.value else {
            skip("environment: removal itself failed (vault dark?) — bar semantics unproven this run")
            return
        }

        // Counts cannot say WHO wrote, so the attribution is by
        // arithmetic: remove()'s own stand-down is mandatory (+1), so
        // a total of exactly +1 proves the queued stop-disarm wrote
        // nothing.
        check(fake.saveCount - savesBefore == 1,
              "exactly one save total — remove()'s own stand-down; the queued stop-disarm stayed barred (saves=\(fake.saveCount))")
        check(!fake.isOnDemandEnabled,
              "the rule ended down — stood down by the removal before the entry went")
        check(fake.removeCount == 1, "the entry was removed exactly once (removePreferences=\(fake.removeCount))")
        check(manager.tunnels.contains(where: { $0.id == identity.id }) == false,
              "the tunnel left the list")

        // Nothing may arrive after the deletion either: a save landing
        // now is the re-mint this guard exists to prevent.
        let savesAtEnd = fake.saveCount
        try? await Task.sleep(for: .milliseconds(400))
        check(fake.saveCount == savesAtEnd,
              "no preferences save landed after the entry was deleted (saves=\(fake.saveCount))")
        // The same window read on the ENTRY, which is the only surface
        // that can tell a late LANDING from a late issue: a save is
        // counted when it goes out. Nothing put the configuration back.
        check(!fake.entryExists,
              "and the entry stayed gone rather than being re-minted (entryExists=\(fake.entryExists))")
    }

    /// A drop whose cause the system DOES answer for: the record must
    /// be filed as the failure, and no retry may be spent on it.
    private func beltFilesRecord() async {
        let record = NSError(domain: "TE.Seam", code: 41,
                             userInfo: [NSLocalizedDescriptionKey: "driven start failure"])
        guard let rig = await activatedRig(name: "TE-Seam-Record-\(runTag)", configure: {
            $0.disconnectAnswer = .record(record)
        }) else { return }
        rig.fake.drive(.disconnected)
        let landed = await settle(within: 6) { rig.container.lastActivationError != nil }
        check(landed, "the drop was explained — lastActivationError=\(rig.container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        var filedTheRecord = false
        if case .failedWhileActivating(let sys) = rig.container.lastActivationError {
            filedTheRecord = (sys as NSError).domain == record.domain && (sys as NSError).code == record.code
        }
        check(filedTheRecord, "the SYSTEM's record was filed, not a stand-in")
        // A real failure must never become a retry: give a revive
        // every chance to misfire before counting.
        try? await Task.sleep(for: .seconds(2))
        check(rig.fake.startCount == 1, "no retry was spent on an explained failure (starts=\(rig.fake.startCount))")
    }

    /// The anonymous-drop class from the live logs, driven: the system
    /// answers "no record", and the one revive must actually restart
    /// the tunnel. This is the mechanical version of the live-log
    /// proof the field runs kept missing.
    private func beltSpendsRevive() async {
        guard let rig = await activatedRig(name: "TE-Seam-Revive-\(runTag)", configure: {
            $0.disconnectAnswer = .none
        }) else { return }
        rig.fake.drive(.disconnected)
        // The budget covers the belt's WHOLE chain, not just its
        // bounded parts: the unbounded verdict leg can eat readAll's
        // 5s transport ceiling in a vault respawn window, then the
        // "no record" answer, the revive's 1s hold and rung 0's 2s
        // verdict — about 8s worst-case before the second start.
        let revived = await settle(within: 12) { rig.fake.startCount >= 2 }
        if !revived {
            // A miss against a dark vault is the environment, not the
            // machinery — same doctrine as every vault-dependent claim.
            if case .unreachable = await vault.ping() {
                skip("environment: vault dark during the belt's verdict leg — revive timing unprovable this run")
                return
            }
        }
        check(revived, "the one revive restarted the tunnel (starts=\(rig.fake.startCount))")
        check(rig.container.respawnReviveConsumed, "the revive is marked spent")
    }

    /// Same silent drop with the revive already spent: the outcome the
    /// live runs showed — 40s of nothing — must be impossible now.
    /// Either a revive or an error, never neither.
    private func beltStandInAfterSpentRevive() async {
        guard let rig = await activatedRig(name: "TE-Seam-StandIn-\(runTag)", configure: {
            $0.disconnectAnswer = .never
        }) else { return }
        // The `.never` fetch parks a completion the same way `.hangs`
        // parks a save, and a parked completion holds the production
        // bridge's continuation. This one does not reach back to the
        // manager, so the leak is a container and its provider rather
        // than a live observer — but held silence is still residue,
        // and the net drains it. Safe to release late: the belt's own
        // fetch rode `bounded(3)` and dropped this answer long ago.
        onTeardown("held disconnect fetch") { [weak self] in
            let released = rig.fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: no held fetch remained"
                      : "teardown: released \(released) held fetch completion(s)")
        }
        rig.container.respawnReviveConsumed = true
        rig.fake.drive(.disconnected)
        // Two legs before the stand-in can land: the belt's unbounded
        // verdict (up to readAll's 5s transport ceiling when the vault
        // is dark) and then bounded(3) giving up on the mute fetch.
        // The stand-in follows because the revive has no grant left to
        // promise with.
        let explained = await settle(within: 10) { rig.container.lastActivationError != nil }
        if !explained {
            if case .unreachable = await vault.ping() {
                skip("environment: vault dark during the belt's verdict leg — stand-in timing unprovable this run")
                return
            }
        }
        check(explained, "a mute system still left an error behind — lastActivationError=\(rig.container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(rig.fake.startCount == 1, "and no retry was invented (starts=\(rig.fake.startCount))")
    }

    /// The belt's slow tail must not deface a session the OS brought
    /// back while the tail was still fetching.
    private func beltRespectsRevivedSession() async {
        guard let rig = await activatedRig(name: "TE-Seam-Green-\(runTag)", configure: {
            // The record arrives AFTER the session is green again.
            $0.disconnectAnswer = .recordAfter(seconds: 2, NSError(domain: "TE.Seam", code: 42))
        }) else { return }
        rig.container.respawnReviveConsumed = true
        rig.fake.drive(.disconnected)
        try? await Task.sleep(for: .milliseconds(300))
        rig.fake.drive(.connected)
        guard await settle(within: 3, until: { rig.container.status == .active }) else {
            fail("the driven revival never reached the handler — status=\(rig.container.status)")
            return
        }
        // Outwait the late record and the belt's write window.
        try? await Task.sleep(for: .milliseconds(3200))
        check(rig.container.lastActivationError == nil,
              "no failure was written under the revived session — error=\(rig.container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(rig.container.status == .active, "the session stayed green — status=\(rig.container.status)")
    }

    /// The Stage-1 contract, driven end to end: a stop landing inside
    /// the rung's arm-and-save window must win. The save is held open
    /// so the window is real, not raced.
    private func stopBeatsInFlightSave() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Stop-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        fake.saveAnswer = .succeedsAfter(seconds: 1.5)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the stop-rig tunnel")
            return
        }
        manager.startActivation(of: container)
        // The stop lands while the ARM save is verifiably in flight:
        // the counter moves when the save is issued, the answer is
        // still 1.5s away.
        guard await settle(within: 8, until: { fake.saveCount >= 1 }) else {
            skip("environment: the rung never reached its arm save")
            return
        }
        manager.startDeactivation(of: container)
        // Let the held save answer and every queued task run its turn.
        try? await Task.sleep(for: .milliseconds(2500))
        check(fake.startCount == 0, "startTunnel was never called past the stop (starts=\(fake.startCount))")
        check(!fake.isOnDemandEnabled && !fake.storedOnDemand,
              "the recovery rule ended disarmed where it counts — in the store (flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand))")
        check(container.lastActivationError == nil,
              "the stop wears no error — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        let grounded = await settle(within: 3) { container.status == .inactive }
        check(grounded, "the row settled inactive — status=\(container.status)")
    }

    /// The stop path's last undriven branch: the disarm save is
    /// REFUSED. Two promises meet here and both must hold — the
    /// refusal surfaces as `savingFailed` (the RecoverySwitch doc's
    /// "deliberate honesty" case), and the stop still goes out,
    /// because a user's stop outranks our failure to persist a
    /// preference. The flag ends on the re-read store's answer, not on
    /// a guess.
    ///
    /// That last clause only became measurable when the fake learned to
    /// keep its store apart from its flag: the re-read now answers with
    /// what is actually stored, and here that is a rule the refused
    /// save never removed. So the honest ending is ARMED — the app
    /// reporting a rule it failed to clear.
    ///
    /// What is NOT measured here, and the reason it is said out loud:
    /// this rig cannot separate the re-read from the pessimistic
    /// rollback, because the tunnel came in armed and the store still
    /// holds the rule, so both answers are `true`. The load counter
    /// below proves only that the store was ASKED. Telling the two
    /// apart needs a load that REFUSES — the fake can answer that way
    /// now, and the step that spends it belongs to the coverage work,
    /// not here.
    private func refusedDisarmSurfaces() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Refused-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .connected)
        fake.isEnabled = true
        fake.arrangeArmed()
        fake.saveAnswer = .fails(NSError(domain: "TE.Seam", code: 43,
                                         userInfo: [NSLocalizedDescriptionKey: "driven save refusal"]))
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the refused-disarm tunnel")
            return
        }
        let loadsBefore = fake.loadCount
        manager.startDeactivation(of: container)

        let stopped = await settle(within: 3) { fake.stopCount >= 1 }
        check(stopped, "the stop still went out past the refused save (stops=\(fake.stopCount))")
        var surfaced = false
        if case .savingFailed = container.lastActivationError { surfaced = true }
        check(surfaced, "the refusal surfaced as savingFailed — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(fake.loadCount > loadsBefore,
              "the refusal ASKED the store rather than reporting the value it had just written (loads=\(fake.loadCount), before=\(loadsBefore))")
        check(fake.isOnDemandEnabled && fake.storedOnDemand,
              "and the flag carries that answer — still armed — rather than the comfortable half (flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand))")

        // Completing the teardown the fake cannot do on its own: the
        // real session would answer the stop with `.disconnected`.
        fake.drive(.disconnected)
        let grounded = await settle(within: 3) { container.status == .inactive }
        check(grounded, "the row settled inactive once the session answered — status=\(container.status)")
    }

    /// The reload's `ingest` calls `refreshStatus()` on every row it
    /// matches, and a save issued by the rung itself is one of the
    /// things that makes the system broadcast the configuration change
    /// the reload rides in on. So the refresh can land INSIDE the
    /// activation it was triggered by, while the session is still
    /// `.disconnected` — and before this contract existed it overwrote
    /// the optimistic `.activating`, the rung's next guard closed, and
    /// the tunnel never started: no error, no retry, no log, which is
    /// exactly the FAIL signature the field runs kept producing.
    ///
    /// Driven by holding the arm save open, so the refresh lands in a
    /// window that is real rather than raced.
    ///
    /// What this measures is the GATE's rule: each of the two lowering
    /// values is refused, and a raising one still lands. What it does
    /// NOT measure is that `ingest` reaches the row through the gate —
    /// the rig's providers are not vault-backed, so a real reload would
    /// drop them from the list rather than refresh them. That leg rests
    /// on reading the production call sites (the reload's `ingest`,
    /// the observer's non-attempting branch, the watchdog's
    /// withdrawal and the rung save-catch — the last two lower the
    /// flag first, which opens the gate everywhere but a queue-taken
    /// `.waiting` row, and the dying-session step below measures the
    /// watchdog's), which this rig cannot drive from here.
    private func refreshCannotCancelActivation() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Refresh-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        fake.saveAnswer = .succeedsAfter(seconds: 1.5)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the refresh-rig tunnel")
            return
        }
        manager.startActivation(of: container)
        guard await settle(within: 8, until: { fake.saveCount >= 1 }) else {
            skip("environment: the rung never reached its arm save")
            return
        }
        // The exact call ingest makes, against a session the system
        // still reports as down.
        container.refreshStatus()
        check(container.status == .activating,
              "a .disconnected refresh left the attempt alone — status=\(container.status)")

        // `.invalid` is the other reading that funnels to `.inactive`
        // — set silently, so the only writer under test is the refresh
        // itself.
        fake.setStatusSilently(.invalid)
        container.refreshStatus()
        check(container.status == .activating,
              "an .invalid refresh left the attempt alone — status=\(container.status)")

        // `.disconnecting` is the OTHER lowering value, and the only
        // raw case that derives `.deactivating`. It needs its own
        // measurement because it does not funnel to `.inactive`: a gate
        // that tested only the "no session" half would let this one
        // through, and `.deactivating` fails the rung's post-save guard
        // exactly as `.inactive` does.
        fake.setStatusSilently(.disconnecting)
        container.refreshStatus()
        check(container.status == .activating,
              "a .disconnecting refresh left the attempt alone — status=\(container.status)")

        let started = await settle(within: 6) { fake.startCount >= 1 }
        check(started, "the activation still reached startTunnel (starts=\(fake.startCount))")

        // The other half of the rule, and the one a too-wide guard
        // would break: a reading that says a session EXISTS must still
        // land, even on a row the manager is driving. Measured last on
        // purpose: raising the row earlier would fail the rung's own
        // post-save guard and cost the start above.
        //
        // The claim only means something while the row IS driven, so
        // that precondition is asserted rather than assumed — nothing
        // reported `.connected` to the observer, so the attempt flag
        // should still be up, and a future change that lowers it early
        // would otherwise turn this into a check of nothing.
        check(container.isManagerDriven,
              "the row is still manager-driven, so the claim below has something to prove")
        fake.setStatusSilently(.connected)
        container.refreshStatus()
        check(container.status == .active,
              "a .connected refresh still landed — status=\(container.status)")
    }

    /// `.waiting` is a queue slot the system cannot express, so a
    /// system reading can only ever destroy it. The user-visible shape:
    /// switching from A to B stops A, and stopping A saves preferences,
    /// and that save brings the reload round to erase B's slot — so A
    /// goes down, the hand-off guard closes on a row that is no longer
    /// `.waiting`, and B never starts, with nothing on screen to say
    /// why.
    ///
    /// Same limit as the sibling refresh step, and worth repeating
    /// here rather than assumed: what this drives is the GATE, called
    /// the way `ingest` calls it, plus the observer branch below. That
    /// a real reload reaches the row through the gate is not measured —
    /// the rig's providers are not vault-backed, so a real reload would
    /// drop them rather than refresh them.
    ///
    /// The same step also proves where the disarm-others sweep belongs:
    /// C is armed and idle, which is a normal resting state, and the
    /// hand-off reaches rung 0 without passing the public door. With
    /// the sweep at that door, B would have armed its rule beside C's.
    private func refreshCannotDropTheQueue() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-QueueA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-QueueB-\(runTag)", createdAt: Date(), isGhost: false)
        let idC = TunnelIdentity(id: UUID(), name: "TE-Seam-QueueC-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .connected)
        fakeA.isEnabled = true
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .disconnected)
        let fakeC = FakeSlotProvider(name: idC.name, identity: idC, status: .disconnected)
        fakeC.arrangeArmed()                // armed and idle: the resting state

        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB, fakeC],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB, fakeC]),
            vault: vault
        )
        guard let a = manager.tunnels.first(where: { $0.id == idA.id }),
              let b = manager.tunnels.first(where: { $0.id == idB.id }) else {
            fail("side manager did not materialize the queue rig")
            return
        }
        guard a.status == .active else {
            fail("the rig's first tunnel did not start active — status=\(a.status)")
            return
        }

        manager.startActivation(of: b)
        guard b.status == .waiting else {
            fail("the second tunnel did not queue behind the first — status=\(b.status)")
            return
        }

        // The refresh the stop's own save brings round.
        b.refreshStatus()
        check(b.status == .waiting, "the queue slot survived a list refresh — status=\(b.status)")

        // The lowering value that does not funnel to `.inactive`, on
        // the queued row this time: `.disconnecting` derives
        // `.deactivating`, and a slot painted `.deactivating` fails the
        // hand-off guard just as surely as one painted `.inactive`.
        fakeB.setStatusSilently(.disconnecting)
        b.refreshStatus()
        check(b.status == .waiting,
              "a .disconnecting refresh left the queue slot alone — status=\(b.status)")

        // The gate's second writer: the status observer's
        // non-attempting branch. Any row without an attempt in flight
        // reaches it — A's drop below does too — but a queued row is
        // the only one the gate can refuse there, because `.waiting` is
        // the only manager-driven state that survives without the
        // attempt flag. A stale `.disconnected` for a queued tunnel
        // used to land, clear the slot, and then run the hand-off
        // against a slot that was already gone.
        //
        // What this adds and what it does not: the rule itself was
        // just proved deterministically by the direct call above, and
        // this drives the WIRING — that the observer's branch reaches
        // the gate at all. It cannot distinguish "the gate held" from
        // "the observer had not run yet", and watching the row for the
        // window rather than reading it once does not change that; it
        // only rules out a slot that flickered and came back.
        fakeB.drive(.disconnected)
        var slotHeld = true
        let watch = Date()
        while Date().timeIntervalSince(watch) < 0.5 {
            if b.status != .waiting { slotHeld = false; break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        check(slotHeld && b.status == .waiting,
              "a driven .disconnected notification left the queue slot alone — status=\(b.status)")

        // A finishes going down; the queued tunnel must take its turn.
        fakeA.drive(.disconnected)
        let tookItsTurn = await settle(within: 12) { fakeB.startCount >= 1 }
        if !tookItsTurn, !manager.tunnels.contains(where: { $0.id == idB.id }) {
            // Not a broken hand-off: the side manager's providers are
            // not vault-backed, so any configuration-change refresh
            // landing inside this step empties its list and takes the
            // queued tunnel with it. Environment, the same way a dark
            // vault is for the belt steps.
            skip("environment: a refresh emptied the side manager's list mid-step")
            return
        }
        check(tookItsTurn, "the queued tunnel took its turn (starts=\(fakeB.startCount))")
        // Reported even when the turn did not happen: the sweep's move
        // is its own contract, and a plain `guard tookItsTurn` here
        // would drop it silently on the one path where the hand-off
        // genuinely broke. The environment exit above is the single
        // deliberate exception, and it says so out loud.
        let sweptC = await settle(within: 5) { !fakeC.storedOnDemand }
        check(sweptC && !fakeC.isOnDemandEnabled,
              "the hand-off disarmed the idle armed tunnel where it counts — in the store (store=\(fakeC.storedOnDemand), flag=\(fakeC.isOnDemandEnabled))")
    }

    /// `remove()` hands the queue on when it finishes, because a queue
    /// slot must not outlive the list it was queued in. That hand-off
    /// runs for the removal of ANY tunnel, including a bystander the
    /// queue was never waiting behind — so it has to read the slot
    /// rather than assume it, and this step drives both answers.
    ///
    /// The order matters: the bystander is deleted while the first
    /// tunnel is still up, which is the shape a user produces by
    /// backing out of a detail sheet mid-delete and toggling another
    /// tunnel. Starting the queued tunnel there would put two sessions
    /// on the system's one slot.
    private func removalHandsOnTheQueue() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-RemA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-RemB-\(runTag)", createdAt: Date(), isGhost: false)
        let idC = TunnelIdentity(id: UUID(), name: "TE-Seam-RemC-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .connected)
        fakeA.isEnabled = true
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .disconnected)
        let fakeC = FakeSlotProvider(name: idC.name, identity: idC, status: .disconnected)

        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB, fakeC],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB, fakeC]),
            vault: vault
        )
        guard let a = manager.tunnels.first(where: { $0.id == idA.id }),
              let b = manager.tunnels.first(where: { $0.id == idB.id }),
              let c = manager.tunnels.first(where: { $0.id == idC.id }) else {
            fail("side manager did not materialize the removal rig")
            return
        }

        manager.startActivation(of: b)
        guard b.status == .waiting else {
            fail("the second tunnel did not queue behind the first — status=\(b.status)")
            return
        }

        // A's session answers the stop the queueing just issued. This
        // is arrangement, not measurement, and the step is worthless
        // without it — in two opposite directions, which is why it is
        // spelled out rather than left to the reader.
        //
        // The fake would otherwise still read `.connected`, and its id
        // is not vault-backed, so rung 0's pre-flight would call the
        // slot FOREIGN and cancel any start. Phase 1's counter check
        // would then pass while proving nothing (no start was possible
        // either way), and phase 2's hand-off check would go RED on a
        // perfectly correct product. A false green and a false red from
        // one missing line.
        //
        // Set silently, so phase 2's "no notification driven"
        // isolation survives, and `.disconnecting` rather than
        // `.disconnected` because the manager's own row for A reads
        // `.deactivating` and the two should agree.
        fakeA.setStatusSilently(.disconnecting)

        // FIRST: delete the bystander while A still holds the slot.
        guard (try? await manager.remove(tunnel: c)) != nil else {
            skip("environment: removing the bystander failed (vault dark?)")
            return
        }
        guard manager.tunnels.contains(where: { $0.id == idB.id }) else {
            skip("environment: a refresh emptied the side manager's list mid-step")
            return
        }
        check(manager.tunnels.contains(where: { $0.id == idC.id }) == false, "the bystander left the list")
        // Read first and without a window: the removal's hand-off DID
        // run, and had its occupancy test not stopped it, the slot
        // would already be nil — that write is synchronous and lands
        // before anything else the hand-off does. Placed ahead of the
        // settle below so a refresh landing inside that second cannot
        // clear the slot underneath the claim.
        check(manager.waitingTunnel === b, "the slot itself is still held for B")
        // The counter needs the opposite treatment: the rung a hand-off
        // would spawn cannot run an instruction until this body
        // suspends, so an immediate read says zero whether the
        // occupancy test held or not.
        let startedEarly = await settle(within: 1) { fakeB.startCount > 0 }
        check(!startedEarly,
              "the removal did not start the queued tunnel over a session the manager still shows as going down (starts=\(fakeB.startCount))")
        check(b.status == .waiting, "and the queue slot survived the removal — status=\(b.status)")

        // THEN: delete the BLOCKER, and drive nothing. No status
        // notification is posted for A, so the observer's hand-off
        // cannot run — the only hand-off left in the system is the one
        // `remove()` makes itself. Delete that line and this is the
        // check that goes red.
        guard (try? await manager.remove(tunnel: a)) != nil else {
            skip("environment: removing the blocker failed (vault dark?)")
            return
        }
        let tookItsTurn = await settle(within: 12) { fakeB.startCount >= 1 }
        if !tookItsTurn, !manager.tunnels.contains(where: { $0.id == idB.id }) {
            skip("environment: a refresh emptied the side manager's list mid-step")
            return
        }
        check(tookItsTurn,
              "removing the blocker handed the queue on with no notification in sight (starts=\(fakeB.startCount))")
    }

    /// The hand-off's other precondition: a queue slot whose tunnel is
    /// no longer in the list is stale, and it must be discarded rather
    /// than acted on. Starting a row the manager does not list would
    /// raise a session nothing in the app is tracking.
    ///
    /// Driven through the reload, which is the one pass that drops rows
    /// without touching the slot. The rig's providers are synthetic, so
    /// the owner-scoped vault does not back them and an ingest scoped
    /// by ownership drops all of them — the same shape a real reload
    /// produces when an entry leaves the system store.
    ///
    /// Expect two production log lines from this step, and read neither
    /// as a fact about the machine: the ownership line reports keeping
    /// 0 of this rig's 2 synthetic providers and files them as other
    /// users', and — when the real vault holds payloads — a reconcile
    /// line claims to have restored tunnels the system had lost. Both
    /// describe the side manager's private list. Nothing is WRITTEN to
    /// the real system store or the real vault: the stand-ins reconcile
    /// mints come from the rig's own fake factory. The vault is READ,
    /// though, and on two counts: the ownership boundary has always
    /// probed per id for a provider the bulk answer did not cover (this
    /// rig's two synthetic ones), and since the custody-read package
    /// the reconcile behind it probes once more per PAYLOAD the rig's
    /// list lacks — on a machine holding real tunnels, one round-trip
    /// each, which is where this step's wall clock goes.
    private func staleQueueSlotIsDiscarded() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-StaleA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-StaleB-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .connected)
        fakeA.isEnabled = true
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .disconnected)

        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB]),
            vault: vault
        )
        guard let b = manager.tunnels.first(where: { $0.id == idB.id }) else {
            fail("side manager did not materialize the stale-slot rig")
            return
        }
        manager.startActivation(of: b)
        guard b.status == .waiting, manager.waitingTunnel === b else {
            fail("the rig did not park a queue slot — status=\(b.status)")
            return
        }
        // Same arrangement, same reason as the removal step: left
        // `.connected`, this unbacked fake would make rung 0's
        // pre-flight call the slot foreign, and then no start could
        // happen in the regression case either — the closing check
        // below would be measuring a world where it had nothing to
        // catch.
        fakeA.setStatusSilently(.disconnecting)

        // The pass the app runs on every configuration change and every
        // return to the foreground.
        await manager.refresh()
        guard manager.tunnels.contains(where: { $0.id == idB.id }) == false else {
            skip("environment: the reload kept the unbacked row, so there is no stale slot to discard")
            return
        }

        // The discriminating claim, and it is synchronous: a hand-off
        // that acted on the stale slot would have painted the row
        // `.activating` on its way into rung 0, before any await.
        check(b.status == .waiting, "the unlisted row was left alone — status=\(b.status)")
        check(manager.waitingTunnel == nil, "and the stale slot was discarded rather than kept")
        let started = await settle(within: 1) { fakeB.startCount > 0 }
        check(!started, "no session was raised for a row the list no longer holds (starts=\(fakeB.startCount))")
    }

    /// The floor under everything else on the activation path: an
    /// attempt that can neither proceed nor fail must not be allowed to
    /// last.
    ///
    /// Driven by the one shape no guard sees coming — a preferences
    /// save that never answers. Nothing else can move the attempt after
    /// that: the rung is suspended inside the save, and the retry
    /// ladder is only scheduled past a successful start, so there is no
    /// timer either. Before the ceiling this row stayed `.activating`
    /// for the life of the process.
    ///
    /// The ladder is scaled down for the rig. That pacing is injected
    /// precisely so a contract which only expresses itself at the end
    /// of an attempt can be measured by a step that has to finish. At
    /// 1.0s and two rungs the ceiling lands at five seconds — three
    /// rungs' worth plus the pre-flight's own two-second budget, which
    /// the formula carries rather than assuming it away. The save is
    /// therefore always issued first, with three seconds of margin
    /// over the pre-flight's worst case. Wall-clock on the green path:
    /// the ceiling's five, the retry window's three, and the
    /// post-release quiet window — about eleven in all.
    private func wedgedAttemptIsWithdrawn() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Wedged-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        fake.saveAnswer = .hangs
        // `observesSystemChanges: false` — this step holds a wedge for
        // eleven seconds, and a real configuration change or an app
        // switch inside that window used to reload the side manager,
        // drop the vault-unbacked fake as foreign, and skip the step.
        // The rig needs no reloads (nothing here drives one), so the
        // hazard is simply not subscribed to.
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            retryInterval: 1.0,
            maxRetries: 2,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the wedged-attempt tunnel")
            return
        }
        // The wedge has to be released or it never ends: the held save
        // completion keeps the production bridge's continuation alive,
        // that keeps the rung task alive, and the rung task holds this
        // manager. With the reload triggers unsubscribed the leak no
        // longer runs vault passes — the residue is the suspended
        // continuation, the rung task, this container and a
        // status-observer-only manager — but held silence is still
        // residue, and the drain is still what ends it. Registered
        // before the activation so it fires on every exit, including
        // the environment skip below.
        onTeardown("wedged save") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: nothing was still held — the step released the wedge itself"
                      : "teardown: released \(released) held request(s) so the side manager can go")
        }

        manager.startActivation(of: container)
        guard await settle(within: 8, until: { fake.saveCount >= 1 }) else {
            skip("environment: the rung never reached its arm save")
            return
        }
        // Captured here, where it means one thing: the arm save, and
        // nothing else, has been issued. Taking it after the
        // withdrawal would fold in the withdrawal's OWN disarm save and
        // leave the totals below saying nothing.
        let savesAtArm = fake.saveCount
        check(container.status == .activating,
              "the attempt is wedged inside a save that will never answer — status=\(container.status)")

        // No environment exemption here any more: with the reload
        // triggers unsubscribed, nothing can empty this rig's list —
        // the watchdog either fires or the product broke its floor.
        let explained = await settle(within: 8) { container.lastActivationError != nil }
        check(explained,
              "the ceiling withdrew it — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        var named = false
        if case .activationUnresolved = container.lastActivationError { named = true }
        check(named, "and said the system never answered rather than inventing an error it did not give")
        check(container.status == .inactive, "the row came back to rest — status=\(container.status)")
        check(!container.isAttemptingActivation, "the attempt flag came down with it")

        // The half of the contract that says WITHDRAWS, never retries.
        // Measured on the save counter rather than the start counter,
        // because a wedged rig can never reach `startTunnel` at all: a
        // start count of zero is true whatever the withdrawal does,
        // while a retry it wrongly spawned would climb rung 0 and issue
        // a save. The arithmetic names the contract — the arm save,
        // plus the withdrawal's own disarm, and nothing else.
        //
        // Watched past a rung-0 re-entry's worst case rather than past
        // the retry interval alone: a spawned rung spends the
        // pre-flight's budget before its save would appear, and sizing
        // the window on the interval alone left about a tenth of a
        // second of slack.
        let window = manager.preflightBudget + manager.retryInterval
        let climbedAgain = await settle(within: window) { fake.saveCount > savesAtArm + 1 }
        // Exact equality, both bounds at once: fewer would mean the
        // withdrawal never issued its own stand-down, more would mean
        // a retry was climbed on top of the wedge.
        check(!climbedAgain && fake.saveCount == savesAtArm + 1,
              "exactly the arm save and the withdrawal's own stand-down (saves=\(fake.saveCount), expected \(savesAtArm + 1))")
        // No startCount claim on purpose: in this rig `startTunnel` is
        // unreachable whatever the product does — the save it sits
        // behind never answers — so asserting zero would be a check
        // that cannot fail, and this file calls that decoration.

        // The owner sweeps its own residue; the net stays registered
        // for the paths that never reach this line. Releasing here also
        // keeps the wedge from outliving the step by the length of the
        // rest of the workflow.
        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")

        // Only the disarm's own error report is still sequenced behind
        // the held save — the hand-off deliberately runs ahead of it,
        // so the window above already covered everything user-facing.
        // Nothing after the release may climb: the resumed arm save
        // falls to its attempt-id guard, and the resumed disarm only
        // re-reads.
        let savesAfterRelease = fake.saveCount
        let climbedAfterRelease = await settle(within: manager.preflightBudget + 0.5) {
            fake.saveCount > savesAfterRelease
        }
        check(!climbedAfterRelease,
              "and nothing climbed once the wedge was released (saves=\(fake.saveCount))")
        // The catch guard's red-first witness. The released arm save
        // resumes into the rung's save-catch carrying an error, and
        // only the attempt-id guard there keeps it from stamping
        // `savingFailed` over the withdrawal's verdict — the window
        // above has already given that resume time to land, so this
        // reads the settled truth. Delete the guard and this goes red.
        var verdictKept = false
        if case .activationUnresolved = container.lastActivationError { verdictKept = true }
        check(verdictKept,
              "the late save's refusal could not overwrite the withdrawal's verdict — error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
    }

    /// The watchdog's second cause, and the half of the withdrawal
    /// contract the wedged-save step cannot see: what happens to the
    /// STATUS. A `.disconnecting` that lands mid-attempt paints
    /// `.deactivating` without clearing the flag, the rung closes on
    /// its own guard with nothing scheduled behind it, and if the
    /// system's `.disconnected` never follows the attempt is
    /// unresolved with a session still dying under it.
    ///
    /// The ceiling must withdraw the INTENT — flag down, error named,
    /// rule disarmed — but must NOT flat-ground the row: the system
    /// still holds the dying session, a written `.inactive` would last
    /// exactly one refresh, and its flicker would offer a start
    /// against a slot that is still occupied. So the seal here is
    /// double-edged: the error appears AND the row still reads
    /// `.deactivating`. The step then plays the system's overdue
    /// `.disconnected` and proves the ordinary observer path grounds
    /// the row with the explanation intact.
    ///
    /// Deterministic by construction: the fatal `.disconnecting` is
    /// driven while rung 0 is still inside its pre-flight, so the rung
    /// refuses at its own status guard — no save, no start, no retry
    /// timer ever arms, and the only save the whole step may see is
    /// the withdrawal's own disarm. Wall-clock is the rig ceiling's
    /// five seconds plus the three-second watch window — about nine.
    private func dyingSessionIsWithdrawnInPlace() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Dying-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        // Reload triggers unsubscribed for the same reason as the
        // wedged sibling: a nine-second hold must not be emptied by an
        // app switch. The status observer stays — the drives below
        // ride it.
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            retryInterval: 1.0,
            maxRetries: 2,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the dying-session tunnel")
            return
        }
        // Saves succeed in this rig, so nothing should ever be held —
        // the net is here for the same reason the sibling steps carry
        // one: a step that plants silence must not rely on its own
        // green path to clean it up.
        onTeardown("held completions (dying-session step)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: nothing was held, as this rig intends"
                      : "teardown: released \(released) held request(s)")
        }

        manager.startActivation(of: container)
        // The rung is suspended inside its pre-flight verdict; the
        // session starts dying before it comes back. The observer's
        // attempting branch paints `.deactivating` and leaves the flag
        // up — the exact shape the ceiling exists to resolve.
        fake.drive(.disconnecting)
        let dying = await settle(within: 2) {
            container.status == .deactivating && container.isAttemptingActivation
        }
        check(dying, "the session is dying under an attempt that still holds its intent — status=\(container.status)")
        let savesBeforeWithdrawal = fake.saveCount

        // No environment exemptions in this step: with the reload
        // triggers unsubscribed nothing can empty the rig's list, so
        // a missing withdrawal is the product's failure, never the
        // environment's.
        let explained = await settle(within: 8) { container.lastActivationError != nil }
        check(explained,
              "the ceiling withdrew it — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        var named = false
        if case .activationUnresolved = container.lastActivationError { named = true }
        check(named, "and said the system never answered rather than inventing an error it did not give")
        check(!container.isAttemptingActivation, "the attempt flag came down")
        // The double edge: withdrawn, but NOT grounded. The system
        // still reads `.disconnecting`, so the re-derived status must
        // keep saying so — a flat `.inactive` here is the flicker this
        // step exists to forbid.
        check(container.status == .deactivating,
              "the dying session was left to the system — status=\(container.status)")
        // The disarm save lands on the far side of an executor hop, so
        // its count is not necessarily readable the instant the error
        // is — the withdrawal writes the error BEFORE it issues the
        // save. The equality is therefore asserted only after the
        // watch window, the way the wedged sibling does it, and the
        // window is sized past a rung-0 re-entry's worst case (the
        // pre-flight budget a spawned rung spends before its save
        // would appear), not the retry interval alone.
        let window = manager.preflightBudget + manager.retryInterval
        let climbed = await settle(within: window) {
            fake.saveCount > savesBeforeWithdrawal + 1 || fake.startCount > 0
        }
        // Exactly the withdrawal's own disarm and nothing else: the
        // rung never reached a save (it refused at its status guard),
        // so fewer means the stand-down never went out and more means
        // something climbed over a dying session.
        check(!climbed && fake.saveCount == savesBeforeWithdrawal + 1,
              "exactly the withdrawal's own stand-down (saves=\(fake.saveCount), expected \(savesBeforeWithdrawal + 1))")
        // Zero polices the one class that can actually move in this
        // rig: a wrongly issued rung-0 re-entry — a hand-off or public
        // door that ignored the dying row — repaints `.activating` and
        // climbs through save to start, because saves answer here; it
        // would trip the status and error-survival checks around this
        // one too, since rung 0 clears the error it climbs over. A
        // wrongly SCHEDULED retry, by contrast, parks at its own
        // status guard before either counter moves — that class no
        // counter can see, and it is the product guard itself that
        // neutralizes it.
        check(fake.startCount == 0,
              "no session was ever raised over the dying one (starts=\(fake.startCount))")

        // The system finally finishes the death it owed. The flag is
        // down, so this lands through the observer's non-attempting
        // branch and the ordinary status gate — and the explanation
        // must survive the grounding, because the grounding is not a
        // new verdict, just the old session's tail.
        fake.drive(.disconnected)
        let grounded = await settle(within: 2) { container.status == .inactive }
        check(grounded, "the system's own .disconnected grounded the row once it finally came — status=\(container.status)")
        var explanationSurvived = false
        if case .activationUnresolved = container.lastActivationError { explanationSurvived = true }
        check(explanationSurvived, "and the withdrawal's explanation survived the grounding")
    }

}
#endif
