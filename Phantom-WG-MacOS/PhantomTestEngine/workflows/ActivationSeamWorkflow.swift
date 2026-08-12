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
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))

    // MARK: - Shared rig

    /// One driven tunnel on a side manager, brought to the point every
    /// belt scenario starts from: activation issued, `startTunnel`
    /// observed, session never connected. Returns nil (with the step
    /// verdict already recorded) when that point is not reached.
    private func activatedRig(
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
            try? await Task.sleep(for: .milliseconds(50))
        }
        skip("environment: the rig's activation never reached startTunnel (vault verdict too slow?)")
        return nil
    }

    /// Polls until `condition` holds or the budget runs out.
    private func settle(within seconds: Double, until condition: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if condition() { return true }
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
    /// save landing
    /// after `removePreferences` writes the entry back, armed, with
    /// its vault payload already gone — invisible and undeletable.
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
        fake.isOnDemandEnabled = true          // armed: the stop takes the disarm path
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
        check(!fake.isOnDemandEnabled, "the recovery rule ended disarmed")
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
    private func refusedDisarmSurfaces() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Refused-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .connected)
        fake.isEnabled = true
        fake.isOnDemandEnabled = true
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
        manager.startDeactivation(of: container)

        let stopped = await settle(within: 3) { fake.stopCount >= 1 }
        check(stopped, "the stop still went out past the refused save (stops=\(fake.stopCount))")
        var surfaced = false
        if case .savingFailed = container.lastActivationError { surfaced = true }
        check(surfaced, "the refusal surfaced as savingFailed — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(!fake.isOnDemandEnabled,
              "the flag carries the re-read store's answer rather than a rollback guess")

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
    /// on reading the two production call sites in `TunnelsManager`
    /// (the reload's `ingest` and the observer's non-attempting
    /// branch), neither of which this rig can drive.
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
        fakeC.isOnDemandEnabled = true          // armed and idle: the resting state

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
        let sweptC = await settle(within: 5) { !fakeC.isOnDemandEnabled }
        check(sweptC, "the hand-off disarmed the idle armed tunnel — C armed=\(fakeC.isOnDemandEnabled)")
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
    /// describe the side manager's private list. Nothing reaches the
    /// real system store or the real vault: the stand-ins reconcile
    /// mints come from the rig's own fake factory.
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
}
#endif
