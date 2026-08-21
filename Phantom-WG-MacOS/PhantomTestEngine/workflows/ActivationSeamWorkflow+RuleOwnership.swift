// ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
// ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
// ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
// ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
// ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
// ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
//
// Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
// Licensed under AGPL-3.0 - see LICENSE file for details
// WireGuard® is a registered trademark of Jason A. Donenfeld.
//
// Activation Seam — Rule Ownership
//
// Steps belonging to `ActivationSeamWorkflow`; the registry lives in the
// main file. They drive one question: WHO owns the recovery rule, and what
// a row may wear while the system disagrees with this process about it.
//
// The hard case these steps exist for is a flag that LIES — a disarm save
// that never answered leaves this process believing the rule is down while
// the store still holds it. A row can therefore be grounded and armed at
// the same time, and a sweep that filters on the flag skips precisely the
// rows it was written to clear.
//
// Split off at a type boundary rather than by moving a threshold: the rigs
// and the run tag belong to the main file, the polling helper lives on
// `TestWorkflow`.

#if DEBUG
import Foundation
import NetworkExtension

extension ActivationSeamWorkflow {

    func groundedRowIsStillWithdrawn() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Grounded-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
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
        onTeardown("grounded-row rig") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: nothing was held, as this rig intends"
                      : "teardown: released \(released) held request(s)")
        }

        manager.startActivation(of: container)
        guard await settle(within: 4, until: { fake.startCount >= 1 }) else {
            skip("environment: the rig's activation never reached startTunnel within the ceiling (vault verdict too slow?)")
            return
        }
        check(fake.storedOnDemand,
              "the rung armed the rule in the STORE, which is what the withdrawal below has to clear")

        fake.drive(.disconnecting)
        guard await settle(within: 3, until: { container.status == .deactivating }) else {
            fail("the driven .disconnecting never painted the row — status=\(container.status)")
            return
        }
        let savesAtArm = fake.saveCount
        check(container.isAttemptingActivation && container.activationAttemptId != nil,
              "the attempt is still owned while the session dies under it")

        fake.setStatusSilently(.disconnected)
        container.refreshStatus()
        check(container.status == .inactive,
              "a refresh grounded the row while its attempt was still live — status=\(container.status)")
        check(container.isAttemptingActivation && container.lastActivationError == nil,
              "and the grounding wrote nothing into the ledger: that is what makes the attempt unresolved rather than finished")

        let explained = await settle(within: 8) { container.lastActivationError != nil }
        check(explained,
              "the ceiling still withdrew the attempt from under a grounded row — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        var named = false
        if case .activationUnresolved = container.lastActivationError { named = true }
        check(named, "and named the silence rather than inventing an error the system never gave")
        check(!container.isAttemptingActivation, "the attempt flag came down with it")

        let disarmed = await settle(within: 3) { !fake.storedOnDemand }
        check(disarmed,
              "the recovery rule came down in the store, not just in the flag (store=\(fake.storedOnDemand), flag=\(fake.isOnDemandEnabled))")
        check(fake.saveCount == savesAtArm + 1,
              "exactly the withdrawal's own stand-down followed the arm save (saves=\(fake.saveCount), expected \(savesAtArm + 1))")
    }

    func sweepReachesAStoreOnlyRule() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-SweepA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-SweepB-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .disconnected)
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .connected)
        fakeB.isEnabled = true
        fakeB.arrangeArmed()
        fakeB.saveAnswer = .hangs
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
        onTeardown("wedged stop-disarm (sweep rig)") { [weak self] in
            let released = fakeB.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the sweep rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the sweep rig")
        }

        manager.startDeactivation(of: b)
        guard await settle(within: 5, until: { fakeB.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fakeB.saveCount))")
            return
        }
        check(!fakeB.isOnDemandEnabled && fakeB.storedOnDemand,
              "the wedged stop left the flag down over a rule still in the store (flag=\(fakeB.isOnDemandEnabled), store=\(fakeB.storedOnDemand))")
        check(manager.tunnels.contains(where: { $0.id == idB.id }) && !b.isActivateOnDemandEnabled,
              "and the row is still IN THE LIST while reading disarmed — a listed row is exactly what a flag-filtered sweep walked past")

        fakeB.saveAnswer = .succeeds
        let savesBeforeSweep = fakeB.saveCount

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

        let released = fakeB.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
        manager.startDeactivation(of: a)
    }

    func stopReachesAStoreOnlyRule() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-StopRule-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .connected)
        fake.isEnabled = true
        fake.arrangeArmed()
        fake.saveAnswer = .hangs
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
        guard await settle(within: 5, until: { fake.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fake.saveCount))")
            return
        }
        check(!fake.isOnDemandEnabled && fake.storedOnDemand,
              "the wedged stop left the flag down over a rule still in the store (flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand))")
        check(container.status == .active,
              "and the session it was stopping is still up — status=\(container.status)")

        fake.saveAnswer = .succeeds
        let savesBefore = fake.saveCount
        let stopsBefore = fake.stopCount

        manager.startDeactivation(of: container)
        check(fake.stopCount > stopsBefore,
              "the stop went out BEFORE anything awaited a save (stops=\(fake.stopCount))")

        fake.setStatusSilently(.connecting)
        fake.drive(.connecting)
        let cleared = await settle(within: 3) { !fake.storedOnDemand }
        check(cleared,
              "and the repair behind it stood down the rule its own flag denied (store=\(fake.storedOnDemand), flag=\(fake.isOnDemandEnabled))")
        let restopped = await settle(within: 3) { fake.stopCount >= stopsBefore + 2 }
        check(restopped,
              "and the session the rule brought back was stopped again rather than left running (stops=\(fake.stopCount))")
        check(container.lastActivationError == nil,
              "with no error written over a stop that worked — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(fake.saveCount == savesBefore + 1,
              "exactly the stop's own stand-down followed (saves=\(fake.saveCount), expected \(savesBefore + 1))")

        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
    }

    func revivalClearsTheVerdict() async {
        let record = NSError(domain: "TE.Seam", code: 45,
                             userInfo: [NSLocalizedDescriptionKey: "driven start failure"])
        guard let rig = await activatedRig(name: "TE-Seam-Revival-\(runTag)", configure: {
            $0.disconnectAnswer = .record(record)
        }) else { return }

        rig.fake.drive(.disconnected)
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

        check(!rig.container.isAttemptingActivation,
              "no attempt of ours is in flight, so what follows is the system's own doing")
        rig.fake.drive(.connected)
        let raised = await settle(within: 5) { rig.container.status == .active }
        check(raised, "the session came back up — status=\(rig.container.status)")
        check(rig.container.lastActivationError == nil,
              "and the row shed the older attempt's verdict as it rose — lastActivationError=\(rig.container.lastActivationError.map { String(describing: $0) } ?? "nil")")

        rig.manager.startDeactivation(of: rig.container)
    }

    func giveUpDoesNotGroundALiveSession() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-LiveGiveUp-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
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
        onTeardown("live-give-up rig") { [weak self] in
            let was = container.status
            manager.startDeactivation(of: container)
            self?.log(was == .inactive || was == .deactivating
                      ? "teardown: nothing to stand down (status=\(was))"
                      : "teardown: stood the live-give-up rig's row down from \(was)")
        }

        manager.startActivation(of: container)
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
        let disarmed = await settle(within: 3) { !fake.storedOnDemand }
        check(disarmed && fake.saveCount == 1,
              "and the rule came down in the store, as it does on every other collision belt (store=\(fake.storedOnDemand), saves=\(fake.saveCount), expected 1)")
    }

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
        fake.setStatusSilently(.connecting)
        check(container.status == .activating,
              "the row is still the manager's, wedged inside a save that will never answer — status=\(container.status)")

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
        manager.startDeactivation(of: container)
    }

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
        let disarmed = await settle(within: 3) { !fake.storedOnDemand }
        check(disarmed,
              "the recovery rule came down in the store, so the OS has nothing left to relaunch (store=\(fake.storedOnDemand), flag=\(fake.isOnDemandEnabled))")
        check(fake.startCount == 0,
              "and no session was ever raised from a configuration that would not load (starts=\(fake.startCount))")
    }

    func secondRemovalIsASilentNoOp() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-TwiceRemoved-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
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

    func deleteFlowStopCannotOutrunItsRemoval() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-DeleteOrder-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .connected)
        fake.isEnabled = true
        fake.arrangeArmed()
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

        manager.startDeactivation(of: container)
        guard await settle(within: 3, until: { fake.saveCount >= 1 }) else {
            fail("the armed stop never issued its disarm save (saves=\(fake.saveCount))")
            return
        }
        fake.saveAnswer = .succeeds
        guard let disarmIssuedAt = fake.lastSaveIssuedAt else {
            fail("the armed stop's disarm was counted but never stamped — the wait cannot be measured from an honest origin")
            return
        }
        let removed = await Task { @MainActor in (try? await manager.remove(tunnel: container)) != nil }.value
        let removalTook = Date().timeIntervalSince(disarmIssuedAt)
        guard removed else {
            skip("environment: the removal failed (vault dark?) — the ordering contract is unproven this run")
            return
        }
        check(removalTook >= slowDisarm,
              "the removal waited the stop's disarm out before it finished (took \(String(format: "%.1f", removalTook))s from the save's own issue, the disarm needed \(String(format: "%.1f", slowDisarm))s)")
        check(!manager.tunnels.contains(where: { $0.id == identity.id }), "the tunnel left the list")
        check(fake.removeCount == 1, "the entry was removed exactly once (removePreferences=\(fake.removeCount))")
        check(fake.saveCount == 2,
              "two saves belong to this flow — the stop's disarm and the removal's own stand-down (saves=\(fake.saveCount), expected 2)")

        let reminted = await settle(within: slowDisarm + 3) { fake.entryExists }
        check(!reminted,
              "and no save landed after the entry went — the removal waited the stop's disarm out instead of racing it (entryExists=\(fake.entryExists))")
    }

    func startFailureStandsTheRuleDown() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-StartFail-\(runTag)", createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
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

    func theArmedRuleIsOneConnectRuleForAnyInterface() async {
        guard let (fake, _, _) = await activatedRig(
            name: "TE-Seam-RuleBody-\(runTag)",
            configure: { _ in }
        ) else { return }

        check(fake.isOnDemandEnabled && fake.storedOnDemand,
              "the rung armed the rule and the save landed — flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand)")

        let rules = fake.onDemandRules ?? []
        guard check(rules.count == 1,
                    "exactly one rule was written — rules=\(rules.count), expected 1 (the system evaluates the array in order, so a second entry decides ahead of this one)") else {
            return
        }
        guard let connect = rules[0] as? NEOnDemandRuleConnect else {
            fail("the armed rule is a \(type(of: rules[0])) rather than a connect rule — the array that carries it can just as well carry one that keeps the tunnel down")
            return
        }
        check(connect.interfaceTypeMatch == .any,
              "and it is not narrowed to one interface type, so the recovery covers the network the user actually comes back on "
              + "— interfaceTypeMatch=\(connect.interfaceTypeMatch.rawValue), which is also the framework's default: this reading "
              + "catches a narrowing, not a missing assignment")
    }
}
#endif
