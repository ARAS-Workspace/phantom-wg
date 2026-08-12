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
}
#endif
