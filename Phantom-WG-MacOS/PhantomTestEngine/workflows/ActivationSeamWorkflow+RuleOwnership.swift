#if DEBUG
import Foundation
import NetworkExtension

// The activation seam's rule-ownership family, split off at a type
// boundary rather than by moving a threshold: these steps drive the
// question of WHO owns the recovery rule and what a row may wear while
// the system disagrees. The rigs, the polling helper and the run tag
// belong to `ActivationSeamWorkflow` itself — this is the same
// workflow, continued.
extension ActivationSeamWorkflow {

    /// The watchdog's third cause, and the one that used to disqualify
    /// the watchdog itself: the row is GROUNDED under a live attempt.
    ///
    /// A `.disconnecting` lands mid-attempt and paints `.deactivating`
    /// without touching the ledger — that much the dying-session step
    /// already drives. What follows here is the other half the field
    /// produces: the system's `.disconnected` tail arrives with no
    /// notification behind it (the app was in the background, or the
    /// callback was simply lost), and the next list refresh derives the
    /// row through the status gate — which lets a lowering value land
    /// on a `.deactivating` row on purpose. The row reads `.inactive`,
    /// the attempt ledger is untouched, and nothing is left to advance
    /// it: the rung closed on its own guard long ago.
    ///
    /// While the ceiling read the STATUS, that grounded row was filed
    /// as "resolved" and the watchdog withdrew in silence — no error,
    /// no hand-off, and the rule this activation armed left standing in
    /// the store on a tunnel the manager had given up on. The user saw
    /// a toggle that switched itself off and said nothing.
    ///
    /// So the seal is the ledger, not the paint: the withdrawal must
    /// still happen on a row that already reads `.inactive`, and the
    /// store — not just the flag — must end disarmed. That last half is
    /// only visible because the fake keeps the two apart.
    ///
    /// Deterministic by construction: the rig's own arm save answers,
    /// so the rule really is in the store before anything is grounded,
    /// and the ladder is scaled the way the wedged step's is — two
    /// retries at a second, which the formula counts as three rungs'
    /// worth, plus the pre-flight's own two-second budget: a
    /// five-second ceiling that STARTS at rung 0, pre-flight included.
    /// Wall-clock: that ceiling, plus the settle windows around it —
    /// about seven.
    func groundedRowIsStillWithdrawn() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Grounded-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        // Reload triggers unsubscribed for the wedged step's reason: the
        // rig holds an attempt open across a ceiling, and a real
        // configuration change inside that window would drop the
        // vault-unbacked fake as foreign and empty the list under the
        // measurement.
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            retryInterval: 1.0,
            maxRetries: 2,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the grounded-row tunnel")
            return
        }
        // This rig plants no silence — every answer lands — but the net
        // is registered anyway, before the activation, so the sibling
        // rule holds without exception: what a step arranges, a step
        // does not rely on its own green path to release.
        onTeardown("grounded-row rig") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: nothing was held, as this rig intends"
                      : "teardown: released \(released) held request(s)")
        }

        manager.startActivation(of: container)
        // Shorter than the sibling rigs' eight seconds, and it has to
        // be: this ladder's ceiling is five, so a start observed after
        // that would be racing the very withdrawal under test. Past
        // four seconds the vault is answering too slowly to measure
        // anything here, which is environment, not a broken contract.
        guard await settle(within: 4, until: { fake.startCount >= 1 }) else {
            skip("environment: the rig's activation never reached startTunnel within the ceiling (vault verdict too slow?)")
            return
        }
        check(fake.storedOnDemand,
              "the rung armed the rule in the STORE, which is what the withdrawal below has to clear")

        // The drop that starts it: `.disconnecting` reaches the
        // observer's attempting branch, which paints `.deactivating`
        // and deliberately leaves the ledger alone.
        fake.drive(.disconnecting)
        guard await settle(within: 3, until: { container.status == .deactivating }) else {
            fail("the driven .disconnecting never painted the row — status=\(container.status)")
            return
        }
        // Taken AFTER the row leaves `.activating`, not before: the
        // retry fuse this rig lit is one second long, and a main actor
        // that stalls inside that window would let rung 1 climb and arm
        // a second save — the total below would then be red for a
        // reason that is not the contract. Past this line no rung can
        // arm: the retry's own guard refuses a `.deactivating` row, so
        // the count is exact by construction.
        let savesAtArm = fake.saveCount
        check(container.isAttemptingActivation && container.activationAttemptId != nil,
              "the attempt is still owned while the session dies under it")

        // The tail nobody announced: the session is down, but no
        // notification carries it. `refreshStatus()` is the exact call
        // `ingest` makes on every row a reload matches, and on a
        // `.deactivating` row the gate lets it land.
        fake.setStatusSilently(.disconnected)
        container.refreshStatus()
        check(container.status == .inactive,
              "a refresh grounded the row while its attempt was still live — status=\(container.status)")
        check(container.isAttemptingActivation && container.lastActivationError == nil,
              "and the grounding wrote nothing into the ledger: that is what makes the attempt unresolved rather than finished")

        // The seal. Nothing but the ceiling can end this attempt now.
        let explained = await settle(within: 8) { container.lastActivationError != nil }
        check(explained,
              "the ceiling still withdrew the attempt from under a grounded row — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        var named = false
        if case .activationUnresolved = container.lastActivationError { named = true }
        check(named, "and named the silence rather than inventing an error the system never gave")
        check(!container.isAttemptingActivation, "the attempt flag came down with it")

        // The half the flag alone would lie about: the rule has to
        // leave the STORE. Before the ceiling learned to read this row,
        // this is what survived — an armed connect-on-any-network rule
        // on a tunnel the manager had already given up on.
        let disarmed = await settle(within: 3) { !fake.storedOnDemand }
        check(disarmed,
              "the recovery rule came down in the store, not just in the flag (store=\(fake.storedOnDemand), flag=\(fake.isOnDemandEnabled))")
        // Exact, both bounds: fewer would mean no stand-down was ever
        // issued, more would mean a retry climbed on top of a
        // withdrawal that promises never to retry.
        check(fake.saveCount == savesAtArm + 1,
              "exactly the withdrawal's own stand-down followed the arm save (saves=\(fake.saveCount), expected \(savesAtArm + 1))")
    }

    /// The rung-0 sweep's reach, measured against the one state the
    /// flag cannot describe.
    ///
    /// Recovery is meant to be single-occupancy: the tunnel being
    /// activated owns the rule, everyone else stands down. The sweep
    /// used to pick its targets by reading `isActivateOnDemandEnabled`
    /// — this process's flag — and a flag is not the store. A disarm
    /// save that never answers leaves them disagreeing: the app wrote
    /// the flag down, the rule stayed where it was. Such a row was then
    /// the one row the sweep skipped, so the next activation armed its
    /// rule beside a rule already in the store, while every armed count
    /// in the app (and in this harness) read one — because every one of
    /// them counts the same flag.
    ///
    /// The divergence is produced rather than arranged: a stop whose
    /// disarm save hangs is exactly the shape the field produces. What
    /// is lifted before the measurement is the fake's ANSWER MODE, not
    /// the wedge — the held save stays held until the checks are done,
    /// because answering it would send `standDownRecovery` to its
    /// re-read, repaint the flag from the store, and erase the very
    /// divergence under test.
    func sweepReachesAStoreOnlyRule() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-SweepA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-SweepB-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .disconnected)
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .connected)
        fakeB.isEnabled = true
        fakeB.arrangeArmed()
        // The save that never answers — the producer of the divergence,
        // and the reason the flag ends up lying.
        fakeB.saveAnswer = .hangs
        // Reload triggers unsubscribed for the wedging rigs' reason: the
        // step holds a save open across several seconds, and a real
        // configuration change inside that window would pass these
        // vault-unbacked providers through the ownership boundary and
        // empty the list under the measurement.
        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let a = manager.tunnels.first(where: { $0.id == idA.id }),
              let b = manager.tunnels.first(where: { $0.id == idB.id }) else {
            fail("side manager did not materialize the sweep rig")
            return
        }
        // Registered before anything is wedged, so it fires on every
        // exit including the environment skip below: a held save keeps
        // the production bridge's continuation — and the task that
        // issued it — alive.
        onTeardown("wedged stop-disarm (sweep rig)") { [weak self] in
            let released = fakeB.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the sweep rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the sweep rig")
        }

        manager.startDeactivation(of: b)
        // A contract, not an environment: every answer in this rig is
        // injected, the vault is not on this path, and the armed stop
        // issuing its disarm save is the arrangement itself. If it does
        // not happen, something in the stop broke.
        guard await settle(within: 5, until: { fakeB.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fakeB.saveCount))")
            return
        }
        // The state under test, proved rather than assumed — and it is
        // the app's own bookkeeping that is wrong here, not the fake's:
        // the flag says disarmed, the store still holds the rule.
        check(!fakeB.isOnDemandEnabled && fakeB.storedOnDemand,
              "the wedged stop left the flag down over a rule still in the store (flag=\(fakeB.isOnDemandEnabled), store=\(fakeB.storedOnDemand))")
        check(manager.tunnels.contains(where: { $0.id == idB.id }) && !b.isActivateOnDemandEnabled,
              "and the row is still IN THE LIST while reading disarmed — a listed row is exactly what a flag-filtered sweep walked past")

        // From here the store can answer again — the wedge has already
        // produced the divergence, and a save that never answers would
        // only measure the wedge. The held completion itself stays
        // held (see the doc above).
        fakeB.saveAnswer = .succeeds
        let savesBeforeSweep = fakeB.saveCount

        // The slot has to be free before rung 0 can be reached at all.
        // B's stop is suspended inside its disarm save, so it never got
        // as far as stopping the session: the row is still `.active`,
        // and `beginActivation` would park A as `.waiting` behind it —
        // the sweep would never be issued and this step would measure
        // nothing while reporting a failure. The system's own
        // `.disconnected` ends the SESSION through the observer's
        // non-attempting branch, which touches neither the flag nor the
        // store.
        fakeB.drive(.disconnected)
        guard await settle(within: 3, until: { b.status == .inactive }) else {
            fail("the stopped row never grounded, so rung 0 was never reachable — status=\(b.status)")
            return
        }

        manager.startActivation(of: a)
        let swept = await settle(within: 10) { !fakeB.storedOnDemand }
        check(swept,
              "rung 0 stood down a rule its own flag denied (store=\(fakeB.storedOnDemand), flag=\(fakeB.isOnDemandEnabled))")
        check(fakeB.saveCount > savesBeforeSweep,
              "the sweep issued a save for that row at all (saves=\(fakeB.saveCount), before=\(savesBeforeSweep))")

        // The owner sweeps its own residue; the net stays registered for
        // the paths that never reach this line.
        let released = fakeB.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
        // A climbed a real ladder to get here and left a retry timer
        // behind it. Withdrawing the intent ends both.
        manager.startDeactivation(of: a)
    }

    /// The stop's reach, against the same state the flag cannot
    /// describe — the sweep step's twin, and the more user-visible of
    /// the pair.
    ///
    /// A stop decides whether to stand the rule down by reading the
    /// flag. When a disarm save never answers, the flag goes down over
    /// a rule the store still holds, and from that moment the tunnel is
    /// a trap: every later stop reads the same false flag, skips the
    /// disarm, stops the session — and the surviving
    /// connect-on-any-network rule brings it back. No error is written
    /// anywhere, and nothing inside the app breaks the loop.
    ///
    /// Same producer and same discipline as the sweep step: the wedge
    /// makes the divergence, the answer mode is restored before the
    /// second stop, and the held completion is drained only after the
    /// measurement — draining it first would send `standDownRecovery`
    /// to its re-read, repaint the flag from the store, and erase the
    /// very divergence under test.
    ///
    /// The stop-first order accepts one bounce: for as long as the
    /// repair is in flight, the rule is still in the store and may
    /// bring the session back. That is driven here rather than hoped
    /// away — the revive is played into the window on purpose — because
    /// the branch's answer to it (stop it again, since the user's
    /// withdrawal still stands and no new intent was granted) is the
    /// half that makes the order defensible at all.
    func stopReachesAStoreOnlyRule() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-StopRule-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .connected)
        fake.isEnabled = true
        fake.arrangeArmed()
        fake.saveAnswer = .hangs
        // Reload triggers unsubscribed for the wedging rigs' reason.
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the stop-rule tunnel")
            return
        }
        onTeardown("wedged stop-disarm (stop-rule rig)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the stop-rule rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the stop-rule rig")
        }

        manager.startDeactivation(of: container)
        // A contract, not an environment: nothing here waits on the
        // vault, so an armed stop that issues no disarm save is a
        // broken promise rather than a slow machine.
        guard await settle(within: 5, until: { fake.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fake.saveCount))")
            return
        }
        check(!fake.isOnDemandEnabled && fake.storedOnDemand,
              "the wedged stop left the flag down over a rule still in the store (flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand))")
        // The session is still up, because the stop is suspended in
        // front of it — which is exactly why the user stops again.
        check(container.status == .active,
              "and the session it was stopping is still up — status=\(container.status)")

        // The store can answer again; the held completion stays held.
        fake.saveAnswer = .succeeds
        let savesBefore = fake.saveCount
        let stopsBefore = fake.stopCount

        manager.startDeactivation(of: container)
        // Read with nothing awaited in between, because the ORDER is
        // the contract this branch was shaped around: the stop goes out
        // synchronously and the repair follows it. A settle here would
        // pass just as happily against a save-first shape — the one
        // regression that brings the original trap back.
        check(fake.stopCount > stopsBefore,
              "the stop went out BEFORE anything awaited a save (stops=\(fake.stopCount))")

        // The bounce the stop-first order accepts, driven rather than
        // hoped for: the rule is still in the store at this instant, so
        // this is exactly what it would do — bring the session back
        // between the stop and the repair. The system's `.connecting`
        // reaches the row through the observer's non-attempting branch,
        // which is how a revive looks when no attempt of ours is live.
        fake.setStatusSilently(.connecting)
        fake.drive(.connecting)
        let cleared = await settle(within: 3) { !fake.storedOnDemand }
        check(cleared,
              "and the repair behind it stood down the rule its own flag denied (store=\(fake.storedOnDemand), flag=\(fake.isOnDemandEnabled))")
        // The stop the user asked for is not undone by the bounce it
        // invited: with the rule gone and no new intent granted, the
        // repair answers the revived session with a second stop.
        let restopped = await settle(within: 3) { fake.stopCount >= stopsBefore + 2 }
        check(restopped,
              "and the session the rule brought back was stopped again rather than left running (stops=\(fake.stopCount))")
        check(container.lastActivationError == nil,
              "with no error written over a stop that worked — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        // Exact, both bounds: fewer would mean no repair was issued,
        // more would mean the stop pays for more preference writes than
        // the branch budgets for. The bounce costs stops, never saves.
        check(fake.saveCount == savesBefore + 1,
              "exactly the stop's own stand-down followed (saves=\(fake.saveCount), expected \(savesBefore + 1))")

        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
    }

    /// The designed recovery's own success, seen from the row.
    ///
    /// A timeout keeps its rule on purpose: the system is meant to
    /// bring the tunnel back when the network returns. It does — and
    /// until now the row wore the failure of the attempt that came
    /// before, because nothing cleared it on the way up. The user saw a
    /// green tunnel with a red caption under it and had exactly one
    /// move: tear the working session down and start it again by hand.
    ///
    /// Driven end to end through production paths: the belt files a
    /// real system record as the verdict, then the system raises the
    /// session with no attempt of ours in flight — the shape of an
    /// on-demand revival — and the row must shed the verdict as it
    /// rises.
    func revivalClearsTheVerdict() async {
        let record = NSError(domain: "TE.Seam", code: 45,
                             userInfo: [NSLocalizedDescriptionKey: "driven start failure"])
        guard let rig = await activatedRig(name: "TE-Seam-Revival-\(runTag)", configure: {
            $0.disconnectAnswer = .record(record)
        }) else { return }

        // The drop the system explains: the belt files its record and
        // spends no revive on it.
        rig.fake.drive(.disconnected)
        // Ten seconds, and the environment exit beside it, for the
        // sibling belt steps' reason: the belt asks for a collision
        // verdict before it files anything, and that leg rides the
        // vault with no deadline of its own — a dark vault makes it
        // slow, which is not this contract failing.
        guard await settle(within: 10, until: { rig.container.lastActivationError != nil }) else {
            if !rig.manager.tunnels.contains(where: { $0 === rig.container }) {
                skip("environment: a refresh emptied the side manager's list mid-step")
            } else if case .unreachable = await vault.ping() {
                skip("environment: vault unreachable — the belt's verdict leg never answered")
            } else {
                fail("the drop was never explained, so there is no verdict to shed — error=nil")
            }
            return
        }
        check(rig.container.status == .inactive,
              "the row is down and wearing the failure — status=\(rig.container.status)")

        // The revival: the system raises the session on its own, which
        // reaches the row through the observer's non-attempting branch.
        check(!rig.container.isAttemptingActivation,
              "no attempt of ours is in flight, so what follows is the system's own doing")
        rig.fake.drive(.connected)
        let raised = await settle(within: 5) { rig.container.status == .active }
        check(raised, "the session came back up — status=\(rig.container.status)")
        check(rig.container.lastActivationError == nil,
              "and the row shed the older attempt's verdict as it rose — lastActivationError=\(rig.container.lastActivationError.map { String(describing: $0) } ?? "nil")")

        // Ends the rig rather than leaving a live session behind it.
        rig.manager.startDeactivation(of: rig.container)
    }

    /// The flat ground, and what it costs when the system disagrees.
    ///
    /// A give-up exit used to write `.inactive` by hand. When the
    /// system was in fact holding a session — and rung 0's collision
    /// exit is reached exactly when it is, because a session is what
    /// the classifier saw — that write was a lie with a lifetime: it
    /// stood until the next refresh, and while it stood the interface
    /// offered a start against an occupied slot.
    ///
    /// Two contracts in one rig, because one produces the other: the
    /// exit must stand the recovery rule down (it proved a foreign
    /// holder, and an armed rule against an occupied slot is what feeds
    /// the cross-user fight), and it must then take the system's own
    /// reading rather than the ground it used to assume.
    func giveUpDoesNotGroundALiveSession() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-LiveGiveUp-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        // Armed before anything runs: the rule this exit has to clear
        // has to exist first, in the store as well as the flag.
        fake.arrangeArmed()
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the live-give-up tunnel")
            return
        }
        // Registered before the activation so it fires on every exit,
        // the environment skip included: this rig raises a session that
        // nothing else will take down, and an abandoned ladder would go
        // on re-arming and re-starting for its whole retry budget.
        onTeardown("live-give-up rig") { [weak self] in
            let was = container.status
            manager.startDeactivation(of: container)
            self?.log(was == .inactive || was == .deactivating
                      ? "teardown: nothing to stand down (status=\(was))"
                      : "teardown: stood the live-give-up rig's row down from \(was)")
        }

        manager.startActivation(of: container)
        // Set silently, and only now: the row had to be `.inactive` for
        // the activation door to open. From here the provider reads as
        // a live session on an id the vault does not back, which is
        // exactly what rung 0's pre-flight classifies as a foreign
        // holder — the collision exit under test.
        fake.setStatusSilently(.connected)

        guard await settle(within: 10, until: { container.status != .activating }) else {
            skip("environment: rung 0 never reached its collision verdict (vault too slow?)")
            return
        }
        check(container.status == .active,
              "the give-up took the system's own reading instead of grounding a live session — status=\(container.status)")
        check(container.lastActivationError == nil,
              "and wrote no verdict over it — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(!container.isAttemptingActivation,
              "the attempt itself was withdrawn, which is what opened the gate for that reading")
        check(!fake.isEnabled,
              "and the manager was never enabled against an occupied slot (isEnabled=\(fake.isEnabled))")
        // Exact, like the pre-flight's own step: the collision path
        // owes this row a stand-down and nothing else. More saves would
        // mean an arm slipped in beside it.
        let disarmed = await settle(within: 3) { !fake.storedOnDemand }
        check(disarmed && fake.saveCount == 1,
              "and the rule came down in the store, as it does on every other collision belt (store=\(fake.storedOnDemand), saves=\(fake.saveCount), expected 1)")
    }

    /// The watchdog's quietest exit: the peek.
    ///
    /// Past the ceiling the floor asks the SYSTEM before it writes
    /// anything, and a reading that says a session exists — connecting,
    /// reasserting, connected — means the attempt is late rather than
    /// unresolved. The watchdog withdraws from it in silence: no
    /// verdict, no hand-off, and above all no disarm, because the rule
    /// belongs to the session the system is still bringing up.
    ///
    /// Nothing in the suite reached this branch before: it writes
    /// nothing and logs nothing, so the only observable it leaves is
    /// the save that does NOT happen. That is what the arithmetic here
    /// reads — the sibling wedged step expects the arm save plus the
    /// withdrawal's stand-down; this one expects the arm save alone.
    func peekLeavesARisingSessionAlone() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Peek-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        fake.saveAnswer = .hangs
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            retryInterval: 1.0,
            maxRetries: 2,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the peek tunnel")
            return
        }
        onTeardown("wedged arm save (peek rig)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the peek rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the peek rig")
        }

        manager.startActivation(of: container)
        guard await settle(within: 8, until: { fake.saveCount >= 1 }) else {
            skip("environment: the rung never reached its arm save")
            return
        }
        let savesAtArm = fake.saveCount
        // The system starts speaking while the attempt is wedged. Set
        // silently: the observer is not the writer under test here, the
        // watchdog's own peek is.
        fake.setStatusSilently(.connecting)
        check(container.status == .activating,
              "the row is still the manager's, wedged inside a save that will never answer — status=\(container.status)")

        // Past the ceiling by a margin, and the margin is derived
        // rather than typed: a change to the rig's pacing must not
        // quietly turn this into a check that cannot fail.
        let ceilingPassed = await settle(within: manager.activationCeiling + 3) {
            container.lastActivationError != nil
        }
        check(!ceilingPassed,
              "the ceiling wrote no verdict over a session the system says exists — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(container.isAttemptingActivation,
              "and left the attempt where it was rather than withdrawing it")
        check(fake.saveCount == savesAtArm,
              "no stand-down was issued, because the rule belongs to the session still coming up (saves=\(fake.saveCount), expected \(savesAtArm))")

        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
        // No ladder outlives the measurement: the intent this step
        // granted is withdrawn like every sibling rig's.
        manager.startDeactivation(of: container)
    }

    /// The local give-up's loop trap, and the doctrine that answers it.
    ///
    /// A configuration that will not load fails the same way on every
    /// system-initiated retry, so a rule left armed over it is a trap:
    /// the OS relaunches a tunnel that cannot start, for ever. The exit
    /// stands the rule down for exactly that reason — and until the
    /// fake could refuse a re-read, nothing in the suite had ever
    /// driven the branch at all.
    func loadFailureStandsTheRuleDown() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-LoadFail-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        fake.loadAnswer = .fails(NSError(domain: "TE.Seam", code: 46,
                                         userInfo: [NSLocalizedDescriptionKey: "driven load refusal"]))
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the load-failure tunnel")
            return
        }

        onTeardown("load-failure rig") { [weak self] in
            manager.startDeactivation(of: container)
            self?.log("teardown: the load-failure rig's intent was withdrawn")
        }

        manager.startActivation(of: container)
        // No environment exit, and that is measured rather than
        // assumed: the only wait on this path is rung 0's collision
        // verdict, which is hard-bounded by the pre-flight budget, so
        // ten seconds cannot expire for any reason outside the product.
        guard await settle(within: 10, until: { container.lastActivationError != nil }) else {
            fail("the load failure was never filed — lastActivationError=nil")
            return
        }
        var named = false
        if case .loadingFailed = container.lastActivationError { named = true }
        check(named,
              "the exit named the configuration rather than inventing a system failure — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(container.status == .inactive, "the row came back to rest — status=\(container.status)")
        check(!container.isAttemptingActivation, "and the attempt came down with it")
        // The half that matters after a local give-up: the rule cannot
        // stay armed over a configuration that will never load.
        let disarmed = await settle(within: 3) { !fake.storedOnDemand }
        check(disarmed,
              "the recovery rule came down in the store, so the OS has nothing left to relaunch (store=\(fake.storedOnDemand), flag=\(fake.isOnDemandEnabled))")
        check(fake.startCount == 0,
              "and no session was ever raised from a configuration that would not load (starts=\(fake.startCount))")
    }

    /// The latch is a SET, so it belongs to exactly one caller.
    ///
    /// Two removals of the same tunnel can overlap — the detail sheet
    /// stays up for the seconds a removal takes, and its button can be
    /// pressed again — and while the second one ran, the first one's
    /// `defer` lowered the bar for both. Every deferred writer on these
    /// paths reads that bar to decide whether it may still write, so
    /// the second half of an overlapping pair ran with its own bar
    /// already down, and the system entry was removed twice.
    ///
    /// The second entrance is a silent no-op by decision: nothing went
    /// wrong, the deletion the user asked for is in flight, and an
    /// error banner over it would be a lie they have to act on. So the
    /// contract is counted rather than thrown — one `removePreferences`
    /// for one tunnel, whatever the user pressed.
    func secondRemovalIsASilentNoOp() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-TwiceRemoved-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        // The removal is held open long enough to press again inside it.
        fake.removeAnswer = .succeedsAfter(seconds: 3)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the twice-removed tunnel")
            return
        }

        let first = Task { @MainActor in (try? await manager.remove(tunnel: container)) != nil }
        guard await settle(within: 5, until: { manager.removingIds.contains(identity.id) }) else {
            _ = await first.value
            skip("environment: the removal never reached its in-flight window (vault slow?)")
            return
        }
        // The second press, squarely inside the first removal.
        let second = Task { @MainActor in (try? await manager.remove(tunnel: container)) != nil }
        let secondAnswered = await second.value
        check(secondAnswered,
              "the second removal answered without an error for a deletion that is already happening")
        check(manager.removingIds.contains(identity.id),
              "and it left the bar where it found it — up, because the first removal still owns it")

        let firstAnswered = await first.value
        guard firstAnswered else {
            skip("environment: the removal itself failed (vault dark?) — the latch contract is unproven this run")
            return
        }
        check(fake.removeCount == 1,
              "the system entry was removed exactly once for two presses (removePreferences=\(fake.removeCount))")
        check(!manager.tunnels.contains(where: { $0.id == identity.id }),
              "the tunnel left the list")
        check(!manager.removingIds.contains(identity.id),
              "and the bar came down once, with the removal that owned it")
    }

    /// The delete flow's own ordering, which is the reverse of the one
    /// the sibling step drives.
    ///
    /// `deleteTunnel` stops first and removes second, so the stop's
    /// disarm task is already queued when the removal raises its bar:
    /// the gate reads the bars when the save is ISSUED, finds none, and
    /// that save can then land after `removePreferences` — re-minting
    /// the entry, armed, behind a list that no longer holds it. Whether
    /// its payload is still there depends on the order the removal
    /// chose, and the entry comes back either way. The removal
    /// therefore waits the parked task out in the same bounded window
    /// it waits the rung.
    ///
    /// Measured on the ENTRY, because that is the only place a re-mint
    /// shows: a save is counted when it is ISSUED and lands later, so
    /// no counter can say which side of the removal it fell on. The
    /// counters here are flow accounting — one save for the stop, one
    /// for the removal's own stand-down, one removal — and the entry
    /// carries the contract.
    ///
    /// The seal's window is DERIVED from the delay the step plants: a
    /// window that closes before the planted save lands is a check that
    /// cannot fail, which is how this step's first version passed
    /// against the very bug it was written for.
    func deleteFlowStopCannotOutrunItsRemoval() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-DeleteOrder-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .connected)
        fake.isEnabled = true
        fake.arrangeArmed()                 // armed: the stop takes the disarm path
        // The stop's disarm answers slowly, which is what gives the
        // removal something to outrun. The delay is captured when the
        // save is ISSUED, so the answer mode can be put back to
        // immediate straight afterwards — and it must be, or the
        // removal's own stand-down would inherit the same five seconds
        // and land in step with the one it is racing. Two saves landing
        // out of issue order is exactly the shape under test here.
        let slowDisarm = 2.0
        fake.saveAnswer = .succeedsAfter(seconds: slowDisarm)
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the delete-order tunnel")
            return
        }

        // The user's own sequence, in the app's own order.
        manager.startDeactivation(of: container)
        guard await settle(within: 3, until: { fake.saveCount >= 1 }) else {
            fail("the armed stop never issued its disarm save (saves=\(fake.saveCount))")
            return
        }
        // From here every OTHER save answers at once, so the only slow
        // one in the run is the disarm already in flight.
        fake.saveAnswer = .succeeds
        let startedRemoval = Date()
        let removed = await Task { @MainActor in (try? await manager.remove(tunnel: container)) != nil }.value
        let removalTook = Date().timeIntervalSince(startedRemoval)
        guard removed else {
            skip("environment: the removal failed (vault dark?) — the ordering contract is unproven this run")
            return
        }
        // The wait itself, read directly rather than inferred from what
        // did not happen afterwards: a removal that returned before the
        // planted save could land never waited for it, whatever the
        // entry says later on a slow machine.
        check(removalTook >= slowDisarm,
              "the removal waited the stop's disarm out before it finished (took \(String(format: "%.1f", removalTook))s, the disarm needed \(String(format: "%.1f", slowDisarm))s)")
        check(!manager.tunnels.contains(where: { $0.id == identity.id }), "the tunnel left the list")
        check(fake.removeCount == 1, "the entry was removed exactly once (removePreferences=\(fake.removeCount))")
        check(fake.saveCount == 2,
              "two saves belong to this flow — the stop's disarm and the removal's own stand-down (saves=\(fake.saveCount), expected 2)")

        // The seal, and it is the ENTRY rather than a counter: a save
        // is counted when it is ISSUED and lands later, so no count can
        // say which side of the removal it fell on. The entry can. A
        // stop-disarm that outran its removal puts the configuration
        // back — armed or not, invisible and undeletable, because its
        // payload is already gone.
        // Derived, not typed: the window has to outlive the save this
        // step planted, or it scans the wrong stretch of time and the
        // check becomes decoration.
        let reminted = await settle(within: slowDisarm + 3) { fake.entryExists }
        check(!reminted,
              "and no save landed after the entry went — the removal waited the stop's disarm out instead of racing it (entryExists=\(fake.entryExists))")
    }

    /// The other local give-up: the system refuses the start itself.
    ///
    /// Same doctrine, different evidence — `startTunnel` throwing is
    /// our own start failing, and the rule comes down so the OS does
    /// not spend the rest of the session relaunching it. The fake could
    /// not throw here until this package, so the branch behind that
    /// throw had never been driven either.
    func startFailureStandsTheRuleDown() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-StartFail-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        // A plain domain error on purpose: `.configurationStale` would
        // take the one-shot reload branch instead of the terminal exit
        // under test.
        fake.startAnswer = .fails(NSError(domain: "TE.Seam", code: 47,
                                          userInfo: [NSLocalizedDescriptionKey: "driven start refusal"]))
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the start-failure tunnel")
            return
        }

        onTeardown("start-failure rig") { [weak self] in
            manager.startDeactivation(of: container)
            self?.log("teardown: the start-failure rig's intent was withdrawn")
        }

        manager.startActivation(of: container)
        // Two bounded waits, not an open one: rung 0's pre-flight and
        // the start-catch's own collision verdict, each capped by the
        // pre-flight budget. Twelve seconds is margin over both, so an
        // expiry here is the product failing to file, never a slow
        // machine — which is why it fails rather than skips.
        guard await settle(within: 12, until: { container.lastActivationError != nil }) else {
            fail("the start refusal was never filed — lastActivationError=nil")
            return
        }
        var named = false
        if case .startingFailed = container.lastActivationError { named = true }
        check(named,
              "the system's own refusal was filed rather than a stand-in — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(container.status == .inactive, "the row came back to rest — status=\(container.status)")
        check(fake.startCount == 1,
              "the start was attempted exactly once — a local refusal is not a retry (starts=\(fake.startCount))")
        let disarmed = await settle(within: 3) { !fake.storedOnDemand }
        check(disarmed,
              "and the rule came down in the store, so the OS cannot relaunch a start the system refuses (store=\(fake.storedOnDemand))")
    }
}
#endif
