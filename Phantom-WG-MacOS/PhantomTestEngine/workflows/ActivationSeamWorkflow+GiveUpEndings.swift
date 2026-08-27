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
// Activation Seam — What A Give-Up Leaves Behind
//
// Steps belonging to `ActivationSeamWorkflow`; the registry lives in the
// main file. Give-up endings, each measured for what it leaves rather
// than for how it exits:
//
//   The ladder running out keeps the rule armed BY DECISION. Arming it was
//   the user's explicit intent, and the app does not lower that intent on
//   the user's behalf — the OS may keep trying past our exit, which is the
//   armed rule doing what it was asked, not a leak. A refused arm save
//   leaves the store as it was for the same reason: it wrote nothing, and
//   nothing stands down what it may have left armed. The other give-ups
//   (load-fail, start-fail, foreign holder, the ceiling) stand the rule
//   down; most of their steps live in `+RuleOwnership`.
//
//   The rung-0 pre-flight verdict must reach a row whatever it wears when
//   the verdict lands — `.activating` and `.reasserting` alike. What it
//   takes down there is the attempt FLAG, because the flag alone pins the
//   single slot; what it does not do is also part of the contract — over a
//   live session-implying reading the give-up writes no sentence and
//   leaves the row to the session.
//
//   The ceiling's withdrawals: an attempt the system never answers is
//   withdrawn whole — flag, verdict, stand-down — and a session dying
//   under the attempt is left to the system rather than grounded over.
//
// The ladder and pre-flight rigs answer their slot questions from a
// driven vault, so those verdicts are arrangements rather than whatever
// the real store happens to hold.

#if DEBUG
import Foundation
import NetworkExtension

extension ActivationSeamWorkflow {

    // D2: the two worlds diverge at the store. A give-up that stood the
    // rule down would flip the flag, flip the store, and spend a save this
    // step proves is never spent.
    func ladderRunOutLeavesTheRuleArmed() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-LadderOut-\(runTag)",
                                      createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: identity.name, identity: identity, status: .disconnected)
        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([]))
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: faultVault,
            retryInterval: 1.0,
            maxRetries: 2,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == identity.id }) else {
            fail("side manager did not materialize the ladder-out tunnel")
            return
        }

        manager.startActivation(of: container)
        guard await settle(within: 8, until: { fake.startCount >= 1 }) else {
            skip("environment: the rig's activation never reached startTunnel")
            return
        }
        let ranOut = await settle(within: manager.activationCeiling + 2) {
            if case .retryLimitReached = container.lastActivationError { return true }
            return false
        }
        guard check(ranOut,
                    "the ladder ran out and said so — error="
                    + "\(container.lastActivationError.map { String(describing: $0) } ?? "nil")") else { return }
        check(container.status == .inactive && !container.isAttemptingActivation,
              "the give-up grounded the row and withdrew the attempt — status=\(container.status)")
        check(fake.startCount == 2,
              "having spent exactly its rungs (starts=\(fake.startCount), expected 2)")
        guard check(fake.isOnDemandEnabled && fake.storedOnDemand,
                    "and the rule STAYS ARMED, flag and store alike: arming it was the user's explicit"
                    + " intent, and the app does not lower that intent on the user's behalf"
                    + " (flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand))") else { return }
        let savesAtGiveUp = fake.saveCount
        let disarmOpened = await settle(within: 1.5) { fake.saveCount > savesAtGiveUp }
        check(!disarmOpened && fake.saveCount == savesAtGiveUp,
              "no stand-down save follows the give-up — every save this rig has seen is a rung's own arm"
              + " (saves=\(fake.saveCount))")

        fake.drive(.connected)
        guard await settle(within: 3, until: { container.status == .active }) else {
            fail("the armed rule's own revival never repainted the row — status=\(container.status)")
            return
        }
        check(container.lastActivationError == nil,
              "and the rise takes the give-up sentence down: retryLimitReached named an attempt, and the"
              + " rule doing what the user asked has refuted it — error="
              + "\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")

        manager.startDeactivation(of: container)
        _ = await settle(within: 8) { container.pendingDisarmCount == 0 }
        fake.drive(.disconnected)
        _ = await settle(within: 3) { container.status == .inactive }
    }

    // V1-B6: the pre-flight verdict lands on a row gone `.reasserting` the
    // same way it lands on `.activating`. The FLAG is this step's reading,
    // not the error: over a session-implying reading the give-up leaves
    // the row to the session and writes nothing.
    func preflightVerdictReachesARowGoneReasserting() async {
        let ownName = "TE-Seam-PreflightReassert-\(runTag)"
        let holderName = "TE-Seam-PreflightHolder-\(runTag)"
        guard let ownConfig = TestConfigFactory.throwaway(name: ownName) else {
            fail("the config factory did not produce the throwaway this step needs")
            return
        }
        let own = FakeSlotProvider(name: ownName, identity: ownConfig.identity, status: .disconnected)
        let holder = FakeSlotProvider(
            name: holderName,
            identity: TunnelIdentity(id: UUID(), name: holderName, createdAt: Date(), isGhost: false),
            status: .connected
        )
        let faultVault = FaultVaultClient()
        // The vault owns OUR row, so the classifier reads the holder — and
        // only the holder — as foreign.
        faultVault.readAllAnswer = .answers(.configs([ownConfig]))
        faultVault.readAnswer = .answers(.missing)
        let manager = TunnelsManager(
            tunnelProviders: [own],
            providerFactory: FakeSlotFactory(canned: [own, holder]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == ownConfig.id }) else {
            fail("side manager did not materialize the pre-flight rig")
            return
        }

        manager.startActivation(of: container)
        // Same turn as the press: the rung task has not begun its
        // pre-flight yet, so the repaint is provably inside the window.
        own.setStatusSilently(.reasserting)
        container.refreshStatus()
        guard check(container.status == .reasserting && container.isAttemptingActivation,
                    "the row went .reasserting inside its own rung-0 pre-flight with the attempt flag still"
                    + " up — the window under test is open") else { return }

        let flagCameDown = await settle(within: manager.preflightBudget + 3) {
            !container.isAttemptingActivation
        }
        check(flagCameDown,
              "the proven foreign holder's give-up reached the row gone .reasserting and lowered the"
              + " attempt flag — the flag alone pins the single slot, so a guard written for .activating"
              + " would leave it pinned here (flag=\(container.isAttemptingActivation))")
        check(container.lastActivationError == nil,
              "and wrote no sentence over it: the live reading implies a session, so the give-up leaves"
              + " the row to the session rather than grounding it — error="
              + "\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(container.status == .reasserting,
              "with the row still showing the system's own reading — status=\(container.status)")
        check(own.startCount == 0,
              "and no start ever went out past the verdict (starts=\(own.startCount))")

        manager.startDeactivation(of: container)
        own.drive(.disconnected)
        _ = await settle(within: 3) { container.status == .inactive }
    }

    func wedgedAttemptIsWithdrawn() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Wedged-\(runTag)", createdAt: Date(), isGhost: false)
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
            fail("side manager did not materialize the wedged-attempt tunnel")
            return
        }
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
        let savesAtArm = fake.saveCount
        check(container.status == .activating,
              "the attempt is wedged inside a save that will never answer — status=\(container.status)")

        let explained = await settle(within: 8) { container.lastActivationError != nil }
        check(explained,
              "the ceiling withdrew it — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        var named = false
        if case .activationUnresolved = container.lastActivationError { named = true }
        check(named, "and said the system never answered rather than inventing an error it did not give")
        check(container.status == .inactive, "the row came back to rest — status=\(container.status)")
        check(!container.isAttemptingActivation, "the attempt flag came down with it")

        let window = manager.preflightBudget + manager.retryInterval
        let climbedAgain = await settle(within: window) { fake.saveCount > savesAtArm + 1 }
        check(!climbedAgain && fake.saveCount == savesAtArm + 1,
              "exactly the arm save and the withdrawal's own stand-down (saves=\(fake.saveCount), expected \(savesAtArm + 1))")

        let released = fake.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")

        let savesAfterRelease = fake.saveCount
        let climbedAfterRelease = await settle(within: manager.preflightBudget + 0.5) {
            fake.saveCount > savesAfterRelease
        }
        check(!climbedAfterRelease,
              "and nothing climbed once the wedge was released (saves=\(fake.saveCount))")
        var verdictKept = false
        if case .activationUnresolved = container.lastActivationError { verdictKept = true }
        check(verdictKept,
              "the late save's refusal could not overwrite the withdrawal's verdict — error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
    }

    func dyingSessionIsWithdrawnInPlace() async {
        let identity = TunnelIdentity(id: UUID(), name: "TE-Seam-Dying-\(runTag)", createdAt: Date(), isGhost: false)
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
            fail("side manager did not materialize the dying-session tunnel")
            return
        }
        onTeardown("held completions (dying-session step)") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: nothing was held, as this rig intends"
                      : "teardown: released \(released) held request(s)")
        }

        manager.startActivation(of: container)
        fake.drive(.disconnecting)
        let dying = await settle(within: 2) {
            container.status == .deactivating && container.isAttemptingActivation
        }
        check(dying, "the session is dying under an attempt that still holds its intent — status=\(container.status)")
        let savesBeforeWithdrawal = fake.saveCount

        let explained = await settle(within: 8) { container.lastActivationError != nil }
        check(explained,
              "the ceiling withdrew it — lastActivationError=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        var named = false
        if case .activationUnresolved = container.lastActivationError { named = true }
        check(named, "and said the system never answered rather than inventing an error it did not give")
        check(!container.isAttemptingActivation, "the attempt flag came down")
        check(container.status == .deactivating,
              "the dying session was left to the system — status=\(container.status)")
        let window = manager.preflightBudget + manager.retryInterval
        let climbed = await settle(within: window) {
            fake.saveCount > savesBeforeWithdrawal + 1 || fake.startCount > 0
        }
        check(!climbed && fake.saveCount == savesBeforeWithdrawal + 1,
              "exactly the withdrawal's own stand-down (saves=\(fake.saveCount), expected \(savesBeforeWithdrawal + 1))")
        check(fake.startCount == 0,
              "no session was ever raised over the dying one (starts=\(fake.startCount))")

        fake.drive(.disconnected)
        let grounded = await settle(within: 2) { container.status == .inactive }
        check(grounded, "the system's own .disconnected grounded the row once it finally came — status=\(container.status)")
        var explanationSurvived = false
        if case .activationUnresolved = container.lastActivationError { explanationSurvived = true }
        check(explanationSurvived, "and the withdrawal's explanation survived the grounding")
    }
}
#endif
