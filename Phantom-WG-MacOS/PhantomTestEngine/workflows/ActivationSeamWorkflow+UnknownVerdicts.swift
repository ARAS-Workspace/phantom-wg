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
// Activation Seam — Verdicts Over Readings That Went Unknown
//
// Steps belonging to `ActivationSeamWorkflow`; the registry lives in the
// main file. One question shared by every step here: when a reading dies
// mid-flow — a live `.invalid`, painted `.unknown` — or a queued paint
// disagrees with a live session, does the flow still reach its verdict,
// its stop, or its hand-off? The old folding answered some of these with
// silence: a guard written for `.inactive` alone dropped the sentence, a
// withdrawn queue slot painted a live session down, a parked stop left a
// `.deactivating` nothing would ever take down.

#if DEBUG
import Foundation
import NetworkExtension

extension ActivationSeamWorkflow {

    // The repair's refusal and unconfirmed sentences name the SAVE's fate,
    // so they are written whatever the row wears when the verdict lands —
    // a risen row and an unknown row alike. The old painted-status gates
    // dropped both.
    func stopVerdictLandsWhateverTheRowWears() async {
        let refusal = NSError(domain: "TE.Seam", code: 50,
                              userInfo: [NSLocalizedDescriptionKey: "driven save refusal"])
        guard let risen = sideRow("TE-Seam-VerdictRisen-\(runTag)", status: .connected, configure: {
            $0.isEnabled = true
            $0.saveAnswer = .fails(refusal)
        }) else { return }
        risen.manager.startDeactivation(of: risen.container)
        check(risen.fake.stopCount == 1, "the stop went out inline (stops=\(risen.fake.stopCount))")
        risen.container.refreshStatus()
        guard check(risen.container.status == .active,
                    "and the row has RISEN before the repair's verdict — the live session repainted it")
        else { return }
        let saidOnRisen = await settle(within: 5) {
            if case .stopDisarmRefused = risen.container.lastActivationError { return true }
            return false
        }
        check(saidOnRisen,
              "the refusal is still said on the risen row — the sentence names the save's fate, not the"
              + " session's — error=\(risen.container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(risen.container.status == .active,
              "and the risen row keeps its reading under the sentence — status=\(risen.container.status)")

        guard let unknown = sideRow("TE-Seam-VerdictUnknown-\(runTag)", status: .connected, configure: {
            $0.isEnabled = true
            $0.saveAnswer = .fails(refusal)
        }) else { return }
        unknown.manager.startDeactivation(of: unknown.container)
        check(unknown.fake.stopCount == 1, "the stop went out inline (stops=\(unknown.fake.stopCount))")
        unknown.fake.setStatusSilently(.invalid)
        unknown.container.refreshStatus()
        guard check(unknown.container.status == .unknown,
                    "and this row's reading died before the repair's verdict — painted unknown") else { return }
        let saidOnUnknown = await settle(within: 5) {
            if case .stopDisarmRefused = unknown.container.lastActivationError { return true }
            return false
        }
        check(saidOnUnknown,
              "the refusal is said on the unknown row too — a paint with no session claim takes the sentence"
              + " rather than eating it — error=\(unknown.container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(unknown.container.status == .unknown,
              "with the row still showing what is known — status=\(unknown.container.status)")
    }

    // A queued row the rule has already raised live is genuinely the slot's
    // occupant: a third press must stop that session, not paint it down and
    // walk past it.
    func thirdPressStopsTheQueuedRowTheRuleRaised() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-RaisedA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-RaisedB-\(runTag)", createdAt: Date(), isGhost: false)
        let idC = TunnelIdentity(id: UUID(), name: "TE-Seam-RaisedC-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .connected)
        fakeA.isEnabled = true
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .disconnected)
        let fakeC = FakeSlotProvider(name: idC.name, identity: idC, status: .disconnected)
        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB, fakeC],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB, fakeC]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let b = manager.tunnels.first(where: { $0.id == idB.id }),
              let c = manager.tunnels.first(where: { $0.id == idC.id }) else {
            fail("side manager did not materialize the raised-queue rig")
            return
        }

        manager.startActivation(of: b)
        guard check(b.status == .waiting, "the press queued B behind the occupant — status=\(b.status)")
        else { return }
        fakeA.setStatusSilently(.disconnected)
        fakeB.setStatusSilently(.connecting)
        guard check(b.status == .waiting,
                    "the row still wears the queue's paint over a live reading that already implies a session —"
                    + " the disagreement under test") else { return }

        manager.startActivation(of: c)
        check(fakeB.stopCount == 1,
              "the third press stopped the session the rule had raised — the slot it wants is genuinely"
              + " occupied, and the stop goes to the occupant (stops=\(fakeB.stopCount))")
        check(b.status == .deactivating,
              "with the withdrawn row handed to the live reading and painted by its own stop, never painted"
              + " down over a session — status=\(b.status)")
        check(c.status == .waiting && manager.waitingTunnel === c,
              "and the press took the queue behind it — status=\(c.status)")

        fakeB.drive(.disconnected)
        let served = await settle(within: 12) { fakeC.startCount >= 1 }
        check(served,
              "the grounded occupant then hands the queue on — starts=\(fakeC.startCount), expected 1")
        manager.startDeactivation(of: c)
    }

    // The same disagreement, pressed directly: a stop on the queued row the
    // rule raised withdraws the slot, sees the live session, and falls
    // through to stop it in the SAME press. The old path returned at the
    // withdrawal and swallowed the press.
    func stopOnAQueuedRowTheRuleRaisedFallsThrough() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-FallA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-FallB-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .connected)
        fakeA.isEnabled = true
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .disconnected)
        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let b = manager.tunnels.first(where: { $0.id == idB.id }) else {
            fail("side manager did not materialize the fall-through rig")
            return
        }

        manager.startActivation(of: b)
        guard check(b.status == .waiting, "the press queued B behind the occupant — status=\(b.status)")
        else { return }
        fakeA.setStatusSilently(.disconnected)
        fakeB.setStatusSilently(.connecting)

        manager.startDeactivation(of: b)
        check(fakeB.stopCount == 1,
              "one press: the withdrawn slot showed a live session, so the SAME press fell through and"
              + " stopped it (stops=\(fakeB.stopCount))")
        check(manager.waitingTunnel == nil, "the queue slot itself was given up on the way")
        check(b.status == .deactivating,
              "and the row wears the stop over the session it names — status=\(b.status)")

        fakeB.drive(.disconnected)
        let grounded = await settle(within: 3) { b.status == .inactive }
        check(grounded, "the terminal answer grounds the row — status=\(b.status)")
    }

    // An arm save the system refuses must reach its verdict even when the
    // row's reading died mid-rung: the sentence is written, the attempt
    // comes down whole, and the toggle stays alive on the unknown row.
    func armSaveRefusalReachesARowGoneUnknown() async {
        guard let rig = sideRow("TE-Seam-ArmRefusal-\(runTag)", status: .disconnected, configure: {
            $0.saveAnswer = .fails(NSError(domain: "TE.Seam", code: 51,
                                           userInfo: [NSLocalizedDescriptionKey: "driven arm-save refusal"]))
        }) else { return }
        let (fake, container, manager) = rig
        onTeardown("arm-refusal rig") { [weak self] in
            manager.startDeactivation(of: container)
            self?.log("teardown: the arm-refusal rig's intent was withdrawn")
        }

        manager.startActivation(of: container)
        fake.setStatusSilently(.invalid)
        guard await settle(within: 10, until: { container.lastActivationError != nil }) else {
            fail("the refused arm save was never filed — lastActivationError=nil")
            return
        }
        var named = false
        if case .savingFailed = container.lastActivationError { named = true }
        check(named,
              "the exit named the save the system refused —"
              + " error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(container.status == .unknown,
              "on a row whose reading died mid-rung: shown as unknown rather than silently toggled off —"
              + " status=\(container.status)")
        check(container.activationAttemptId == nil && !container.isAttemptingActivation,
              "the attempt came down whole — flag and id — so nothing pins the single slot")

        fake.saveAnswer = .succeeds
        manager.startActivation(of: container)
        let started = await settle(within: 10) { fake.startCount >= 1 }
        check(started,
              "and the toggle is ALIVE on the unknown row — the next press reaches the system"
              + " (starts=\(fake.startCount))")

        // The second leg names the store decision: the same refusal
        // against a store already holding an ARMED rule. The catch stands
        // nothing down — the app does not lower the user's ON intent on
        // their behalf — so the store's reading survives untouched.
        guard let armed = sideRow("TE-Seam-ArmRefusalArmed-\(runTag)", status: .disconnected, configure: {
            $0.isEnabled = true
            $0.arrangeArmed()
            $0.saveAnswer = .fails(NSError(domain: "TE.Seam", code: 54,
                                           userInfo: [NSLocalizedDescriptionKey: "driven arm-save refusal"]))
        }) else { return }
        onTeardown("armed arm-refusal rig") { [weak self] in
            armed.manager.startDeactivation(of: armed.container)
            self?.log("teardown: the armed arm-refusal rig's intent was withdrawn")
        }
        armed.manager.startActivation(of: armed.container)
        armed.fake.setStatusSilently(.invalid)
        guard await settle(within: 10, until: { armed.container.lastActivationError != nil }) else {
            fail("the armed twin's refused save was never filed — lastActivationError=nil")
            return
        }
        check(armed.fake.storedOnDemand,
              "the refused save wrote nothing; what the store held stays — by decision"
              + " (store=\(armed.fake.storedOnDemand))")
    }

    // A parked stop that resumes over a reading with no notification coming
    // takes the derived paint — unknown — and hands the queue on, instead
    // of leaving a Deactivating nothing will ever take down.
    func parkedStopOverADeadReadingPaintsWhatIsKnown() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-DeadReadA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-DeadReadB-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .connected)
        fakeA.isEnabled = true
        fakeA.arrangeArmed()
        fakeA.saveAnswer = .hangs
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .disconnected)
        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let a = manager.tunnels.first(where: { $0.id == idA.id }),
              let b = manager.tunnels.first(where: { $0.id == idB.id }) else {
            fail("side manager did not materialize the dead-reading rig")
            return
        }
        onTeardown("wedged stop-disarm (dead-reading rig)") { [weak self] in
            manager.startDeactivation(of: b)
            let released = fakeA.releaseHeldCompletions()
            self?.log(released == 0
                      ? "teardown: the dead-reading rig's wedge was released by the step itself"
                      : "teardown: released \(released) held request(s) from the dead-reading rig")
        }

        manager.startActivation(of: b)
        guard check(b.status == .waiting,
                    "one press queued B and sent the armed occupant its stop — status=\(b.status)") else { return }
        guard await settle(within: 5, until: { fakeA.saveCount >= 1 }) else {
            fail("the armed stop never reached its disarm save (saves=\(fakeA.saveCount))")
            return
        }
        check(a.pendingDisarmCount == 1 && fakeA.stopCount == 0,
              "the stop is parked on its own disarm save — count=\(a.pendingDisarmCount), stops=\(fakeA.stopCount)")

        fakeA.setStatusSilently(.invalid)
        guard await settle(within: 8, until: { a.pendingDisarmCount == 0 }) else {
            fail("the parked stop never reached its terminal answer — count=\(a.pendingDisarmCount)")
            return
        }
        check(fakeA.stopCount == 1,
              "the stop still went out at the user's patience (stops=\(fakeA.stopCount))")
        check(a.status == .unknown,
              "and the row shows what is known — a reading with no notification coming takes the derived paint"
              + " rather than a Deactivating nothing will ever take down (status=\(a.status))")
        var namedSilence = false
        if case .stopRuleStandDownUnconfirmed = a.lastActivationError { namedSilence = true }
        check(namedSilence,
              "with the save's silence named — error=\(a.lastActivationError.map { String(describing: $0) } ?? "nil")")
        let served = await settle(within: 12) { fakeB.startCount >= 1 }
        check(served,
              "and the queue was handed on past the dead reading — starts=\(fakeB.startCount), expected 1")
        let released = fakeA.releaseHeldCompletions()
        check(released >= 1, "the step released the wedge it planted (released=\(released))")
    }

    // The belt's foreign-holder sentence survives a repaint to unknown
    // inside its own await window: neither the inactive nor the unknown
    // paint carries a session claim, so neither may eat the verdict. The
    // pin sits on the VERDICT leg — the holder's vault probe answers late
    // — because under the verdict-first order (verdict, guards, stand-down,
    // sentence) that await is the window a repaint can land inside; the
    // old stand-down pin held a window the reorder moved behind the guards.
    func beltNamesAForeignHolderOnARowGoneUnknown() async {
        let ownName = "TE-Seam-BeltForeign-\(runTag)"
        let holderName = "TE-Seam-ForeignHolder-\(runTag)"
        let ownIdentity = TunnelIdentity(id: UUID(), name: ownName, createdAt: Date(), isGhost: false)
        let holderIdentity = TunnelIdentity(id: UUID(), name: holderName, createdAt: Date(), isGhost: false)
        let own = FakeSlotProvider(name: ownName, identity: ownIdentity, status: .disconnected)
        let holder = FakeSlotProvider(name: holderName, identity: holderIdentity, status: .disconnected)
        // A driven vault that owns nothing: the holder's probe is the one
        // answer this step delays, and it answers inside the verdict task's
        // own preflight budget so the bound cannot eat the verdict.
        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([]))
        faultVault.readAnswers[holderIdentity.id] = .answersAfter(seconds: 1, .missing)
        let manager = TunnelsManager(
            tunnelProviders: [own],
            providerFactory: FakeSlotFactory(canned: [own, holder]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == ownIdentity.id }) else {
            fail("side manager did not materialize the belt-foreign rig")
            return
        }

        manager.startActivation(of: container)
        guard await settle(within: 8, until: { own.startCount >= 1 }) else {
            fail("the rig's activation never reached startTunnel against a driven vault"
                 + " (starts=\(own.startCount))")
            return
        }
        holder.setStatusSilently(.connected)
        own.drive(.disconnected)
        guard await settle(within: 3, until: { container.status == .inactive }) else {
            fail("the driven drop never grounded the row — status=\(container.status)")
            return
        }
        own.setStatusSilently(.invalid)
        container.refreshStatus()
        guard check(container.status == .unknown,
                    "the row's reading died inside the belt's own window — painted unknown while the verdict"
                    + " is still out") else { return }
        // The pin's own positive control, ahead of the reading it serves:
        // no sentence has landed yet, so the repaint above provably fell
        // inside the verdict window rather than after it.
        guard check(container.lastActivationError == nil,
                    "and the verdict is provably still out as the repaint lands — the pinned probe has not"
                    + " answered") else { return }

        let named = await settle(within: 6) {
            if case .foreignSlotHolder = container.lastActivationError { return true }
            return false
        }
        check(named,
              "the belt still names the foreign holder on the row gone unknown — the guards admit the"
              + " unknown paint and the sentence lands behind the stand-down —"
              + " error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
    }

    // The reordered foreign leg's own bar, from the other side: the guards
    // run BEFORE the stand-down, so a verdict that comes back for an
    // attempt the row no longer wears — a fresh press has minted a new one
    // — stands nothing down and writes nothing. The step above is this
    // one's positive control: the same pin with no fresh press, and the
    // sentence lands.
    func aStaleVerdictStandsNothingDownBehindAFreshPress() async {
        let ownName = "TE-Seam-StaleVerdict-\(runTag)"
        let holderName = "TE-Seam-StaleHolder-\(runTag)"
        let ownIdentity = TunnelIdentity(id: UUID(), name: ownName, createdAt: Date(), isGhost: false)
        let holderIdentity = TunnelIdentity(id: UUID(), name: holderName, createdAt: Date(), isGhost: false)
        let own = FakeSlotProvider(name: ownName, identity: ownIdentity, status: .disconnected)
        let holder = FakeSlotProvider(name: holderName, identity: holderIdentity, status: .disconnected)
        // The holder's probe answers .missing at 1.5s — late enough to hold
        // the stale verdict in flight across the fresh press below, and
        // inside the 2s preflight bound so the verdict really comes back
        // .heldByForeign rather than falling to .free at the bound.
        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([]))
        faultVault.readAnswers[holderIdentity.id] = .answersAfter(seconds: 1.5, .missing)
        let manager = TunnelsManager(
            tunnelProviders: [own],
            providerFactory: FakeSlotFactory(canned: [own, holder]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == ownIdentity.id }) else {
            fail("side manager did not materialize the stale-verdict rig")
            return
        }
        onTeardown("stale-verdict rig") { [weak self] in
            manager.startDeactivation(of: container)
            self?.log("teardown: the stale-verdict rig's fresh press was withdrawn")
        }

        manager.startActivation(of: container)
        guard await settle(within: 8, until: { own.startCount >= 1 }) else {
            fail("the rig's activation never reached startTunnel against a driven vault"
                 + " (starts=\(own.startCount))")
            return
        }
        holder.setStatusSilently(.connected)
        own.drive(.disconnected)
        guard await settle(within: 3, until: { container.status == .inactive }) else {
            fail("the driven drop never grounded the row — status=\(container.status)")
            return
        }
        guard await settle(within: 2, until: { faultVault.readIds.contains(holderIdentity.id) }) else {
            fail("the drop's verdict never asked about the holder — nothing here is in flight to go stale")
            return
        }
        // The fresh press must not earn the same verdict itself: the holder
        // reads as walked-away again before the press's own pre-flight runs.
        holder.setStatusSilently(.disconnected)
        manager.startActivation(of: container)
        guard await settle(within: 8, until: { own.startCount >= 2 }) else {
            fail("the fresh press never reached startTunnel against a driven vault"
                 + " (starts=\(own.startCount))")
            return
        }
        guard check(own.storedOnDemand,
                    "the fresh press's arm has landed in the store, so the readings below have something"
                    + " to lower") else { return }

        // Negative window derived from the pin itself: the stale probe
        // answers at 1.5s, and these readings outlast it with margin.
        _ = await settle(within: 3) { container.lastActivationError != nil || !own.storedOnDemand }
        check(container.lastActivationError == nil,
              "the stale verdict wrote no sentence over the fresh press — the attemptId it rode in on no"
              + " longer names the row's attempt —"
              + " error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        check(own.storedOnDemand && own.isOnDemandEnabled,
              "and it lowered nothing behind the fresh arm — the press's rule still stands in the store"
              + " (store=\(own.storedOnDemand), flag=\(own.isOnDemandEnabled))")
        check(own.saveCount == 2,
              "with no stand-down save spent: two saves total, the two presses' own arms"
              + " (saves=\(own.saveCount))")
    }

    // The same window, other leg: the system's own disconnect record is
    // filed on a row gone unknown. The guard sits ahead of the record and
    // stand-in split, so this one witness covers both sentences' doorway.
    func beltFilesTheRecordOnARowGoneUnknown() async {
        let record = NSError(domain: "TE.Seam", code: 52,
                             userInfo: [NSLocalizedDescriptionKey: "driven late record"])
        guard let rig = sideRow("TE-Seam-BeltRecord-\(runTag)", status: .disconnected, configure: {
            $0.disconnectAnswer = .recordAfter(seconds: 2, record)
        }) else { return }
        let (fake, container, manager) = rig

        manager.startActivation(of: container)
        guard await settle(within: 8, until: { fake.startCount >= 1 }) else {
            skip("environment: the rig's activation never reached startTunnel (vault verdict too slow?)")
            return
        }
        fake.drive(.disconnected)
        guard await settle(within: 3, until: { container.status == .inactive }) else {
            fail("the driven drop never grounded the row — status=\(container.status)")
            return
        }
        fake.setStatusSilently(.invalid)
        container.refreshStatus()
        guard check(container.status == .unknown,
                    "the row's reading died inside the belt's fetch window — painted unknown while the record"
                    + " is still on its way") else { return }

        let filed = await settle(within: 12) { container.lastActivationError != nil }
        check(filed,
              "the belt still filed an explanation on the row gone unknown —"
              + " error=\(container.lastActivationError.map { String(describing: $0) } ?? "nil")")
        var filedTheRecord = false
        if case .failedWhileActivating(let sys) = container.lastActivationError {
            filedTheRecord = (sys as NSError).domain == record.domain && (sys as NSError).code == record.code
        }
        check(filedTheRecord, "and it is the SYSTEM's record, not a stand-in")
    }

    // The queue-slot withdrawal takes performDeactivation's derived-paint
    // contract: an off-session reading is painted as what it IS. The
    // control runs first on the same rig — a withdrawal over a provable
    // rest paints .inactive — then the same door over a dead reading
    // paints .unknown rather than an .inactive nothing proved, and a
    // third leg walks the contract's last arm: a stop already landing
    // (.disconnecting) paints .deactivating, stampless, drawing no second
    // stop at the fall-through.
    func withdrawnQueueSlotOverADeadReadingPaintsWhatIsKnown() async {
        let idA = TunnelIdentity(id: UUID(), name: "TE-Seam-WithdrawA-\(runTag)", createdAt: Date(), isGhost: false)
        let idB = TunnelIdentity(id: UUID(), name: "TE-Seam-WithdrawB-\(runTag)", createdAt: Date(), isGhost: false)
        let fakeA = FakeSlotProvider(name: idA.name, identity: idA, status: .connected)
        fakeA.isEnabled = true
        let fakeB = FakeSlotProvider(name: idB.name, identity: idB, status: .disconnected)
        let manager = TunnelsManager(
            tunnelProviders: [fakeA, fakeB],
            providerFactory: FakeSlotFactory(canned: [fakeA, fakeB]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let b = manager.tunnels.first(where: { $0.id == idB.id }) else {
            fail("side manager did not materialize the withdrawal rig")
            return
        }

        manager.startActivation(of: b)
        guard check(b.status == .waiting,
                    "the press queued B behind the occupant — status=\(b.status)") else { return }
        manager.startDeactivation(of: b)
        guard check(b.status == .inactive,
                    "the control holds first: a toggle-off over a live .disconnected paints the withdrawn"
                    + " row .inactive, the rest that reading proves — status=\(b.status)") else { return }

        manager.startActivation(of: b)
        guard check(b.status == .waiting,
                    "the same row queues again — status=\(b.status)") else { return }
        fakeB.setStatusSilently(.invalid)
        manager.startDeactivation(of: b)
        check(b.status == .unknown,
              "and this time the reading died before the toggle-off: the withdrawn slot takes the derived"
              + " paint — .unknown, not an .inactive nothing proved — status=\(b.status)")
        check(fakeB.stopCount == 0,
              "with no stop chasing a session the system already walked away from (stops=\(fakeB.stopCount))")
        check(manager.waitingTunnel == nil, "and the slot itself was given up both times")

        manager.startActivation(of: b)
        guard check(b.status == .waiting,
                    "the same row queues a third time — status=\(b.status)") else { return }
        fakeB.setStatusSilently(.disconnecting)
        manager.startDeactivation(of: b)
        check(b.status == .deactivating,
              "a stop already landing takes ITS paint at the withdrawal — .deactivating, handed to the"
              + " reading it names rather than flattened — status=\(b.status)")
        check(fakeB.stopCount == 0,
              "and the fall-through draws no second stop from a stop still landing (stops=\(fakeB.stopCount))")
        check(b.stopIssuedAt == nil,
              "the paint is stampless — this door issued no stop, so it opens no slot window")
        check(manager.waitingTunnel == nil, "and the slot was given up on the way")
        fakeB.drive(.disconnected)
        let grounded = await settle(within: 3) { b.status == .inactive }
        check(grounded, "the terminal answer then grounds the row — status=\(b.status)")

        fakeA.drive(.disconnected)
        _ = await settle(within: 3) { manager.tunnels.first(where: { $0.id == idA.id })?.status == .inactive }
    }
}
#endif
