#if DEBUG
import Foundation
import NetworkExtension

// MARK: - Custody writes — which store a removal empties first, and
// what a removal that only half finishes leaves behind.
//
// The file holds three kinds of step, and the difference is what each
// one arranges:
//
//   - Three steps fail one STORE and read which one the removal had
//     already emptied, because an order is only visible in what
//     survives when the second half does not happen.
//   - One holds a SUCCESSFUL removal's window open instead, because the
//     bar it measures — the restore's refusal to re-mint an entry being
//     removed — only exists while the removal is still running.
//   - One fails the ENTRY and then reads the ROW rather than either
//     store: it drives the removal into a world where the row and the
//     system already disagree, and asks what the removal hands back.
//
// The fault vault supplies the failures and the verdict that chooses
// the order; the providers are canned, so the entry side is observable
// too. Nothing reaches the real vault or the system's preferences — as
// in the sibling file, every surface is fabricated, including ones a
// step's own path should never touch.
extension VaultIntegrityWorkflow {

    /// The entry goes first, so a removal that loses its second half
    /// leaves the tunnel whole rather than leaving a secret-less entry.
    ///
    /// This is the order's whole argument. Payload-first fails toward an
    /// entry the ownership boundary hides, the app cannot delete and the
    /// OS still honours; entry-first fails toward a payload reconcile
    /// puts back. The step drives the failure that tells them apart.
    func removalTakesTheEntryFirst() async {
        let name = "TE-Remove-EntryFirst-\(runTag)"
        guard let payload = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the entry-first config")
            return
        }
        let identity = TunnelIdentity(id: payload.id, name: name, createdAt: payload.createdAt, isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
        // A payload that decodes: the order picks entry-first for it.
        faultVault.readAnswers = [payload.id: .answers(.config(payload))]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.readAllAnswer = .answers(.configs([payload]))
        faultVault.storeAnswer = .answers(.done)
        // And the second half fails, which is what makes the order
        // observable at all.
        faultVault.deleteAnswer = .answers(.refused)

        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == payload.id }) else {
            fail("side manager did not materialize the tunnel")
            return
        }

        do {
            try await manager.remove(tunnel: container)
            fail("the removal reported success over a payload delete that was refused")
            return
        } catch {
            log("the removal refused to claim success — \(error.localizedDescription)")
        }

        check(fake.removeCount == 1 && !fake.entryExists,
              "the entry went first and is gone — removes=\(fake.removeCount), entryExists=\(fake.entryExists)")
        check(faultVault.deletedIds.contains(payload.id),
              "and the payload delete was issued behind it, which is where the failure landed")
        check(manager.tunnels.contains(where: { $0.id == payload.id }),
              "the row was not evicted over a removal that did not finish, so the list still agrees with the vault")

        // WHAT THIS STEP DOES NOT MEASURE, said plainly because the
        // omission is the interesting part.
        //
        // The repair half — the trailing pass `remove()` schedules,
        // which is the whole reason entry-first is preferred — has NO
        // witness here or anywhere. Asserting it from this arrangement
        // is harder than it looks: the row is never evicted on this
        // path (the removal throws before it retires the row, and
        // deliberately so), so "wait for the tunnel to come back" is
        // answered by a row that never left, and any such check passes
        // with the production line deleted. Measuring it needs the row
        // dropped first by an ingest that does NOT reconcile, and then
        // an identity test on the container, because a restore mints a
        // NEW provider rather than reviving this fake. That belongs to
        // the restore package, with its own rounds.
    }

    /// A custody row is the exception: its entry is the only anchor its
    /// payload has, so the entry goes LAST.
    ///
    /// `readAll` returns only what decodes, so a restore can never bring
    /// such a payload back; `ingest` rescues it off the entry. Take the
    /// entry first and lose the payload delete, and the secret is locked
    /// in the keychain with nothing left in the app able to name it.
    func removalKeepsACustodyRowsEntryUntilLast() async {
        let name = "TE-Remove-Custody-\(runTag)"
        let id = UUID()
        let identity = TunnelIdentity(id: id, name: name, createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
        // Present, and not decodable: the one shape the order treats
        // differently.
        faultVault.readAnswers = [id: .answers(.undecodable)]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.readAllAnswer = .answers(.configs([]))
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.refused)

        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == id }) else {
            fail("side manager did not materialize the custody row")
            return
        }

        do {
            try await manager.remove(tunnel: container)
            fail("the removal reported success over a payload delete that was refused")
            return
        } catch {
            log("the removal refused to claim success — \(error.localizedDescription)")
        }

        // Both halves in one reading, because the ledger alone cannot
        // see an ORDER: `deletedIds` records that a delete was ISSUED,
        // so pairing it with an untouched entry is what makes "first"
        // a measurement rather than a caption.
        check(faultVault.deletedIds.contains(id) && fake.removeCount == 0,
              "the payload delete went first for a row whose payload does not decode — issued with the entry still untouched")
        // `entryExists` and not `removeCount` again: the line above
        // already proved the entry was never ASKED to go, so repeating
        // that would add nothing. What this adds is that the anchor is
        // still THERE — the property the exemption exists for.
        check(fake.entryExists,
              "and the entry — its only anchor — is still there, so the row can still be seen and deleted again (entryExists=\(fake.entryExists))")
        check(manager.tunnels.contains(where: { $0.id == id }),
              "with the row still on the list to be seen from")
    }

    /// A vault that will not say what it holds gets no removal at all.
    ///
    /// The order is chosen from the payload's verdict, so an answer that
    /// never arrived cannot choose one. Guessing would mean guessing
    /// which residue to risk, and neither is worth guessing.
    func removalRefusesWhenTheVaultWillNotAnswer() async {
        let name = "TE-Remove-Dark-\(runTag)"
        let id = UUID()
        let identity = TunnelIdentity(id: id, name: name, createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.readAllAnswer = .answers(.configs([]))
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == id }) else {
            fail("side manager did not materialize the tunnel")
            return
        }

        do {
            try await manager.remove(tunnel: container)
            fail("the removal proceeded on a verdict that never arrived")
            return
        } catch {
            log("the removal refused outright — \(error.localizedDescription)")
        }

        check(fake.removeCount == 0 && fake.entryExists,
              "the entry was never touched — removes=\(fake.removeCount), entryExists=\(fake.entryExists)")
        check(faultVault.deletedIds.isEmpty,
              "and neither was the payload — deletes=\(faultVault.deletedIds.count), expected 0")
        check(manager.tunnels.contains(where: { $0.id == id }),
              "so the tunnel stands exactly as it did, whole")
    }

    /// A restore must not re-mint the entry a removal has just taken.
    ///
    /// Entry-first opens this window by construction: the entry's own
    /// removal broadcasts a configuration change, the reload behind it
    /// drops the row because the system no longer lists it, and the
    /// restore then sees a payload the system lacks — while the removal
    /// is still inside its payload delete. Minting there lands an entry
    /// just in time for that delete to take its secret away, which is
    /// the hidden entry the whole package exists to prevent, minted by
    /// the pass itself.
    ///
    /// The reload is what makes this measurable: without it the row is
    /// still listed and the candidate filter refuses on the LIST rather
    /// than on the removal, so the bar under test would never be read.
    func reconcileDoesNotReMintAnEntryBeingRemoved() async {
        let name = "TE-Remove-Remint-\(runTag)"
        guard let payload = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the re-mint config")
            return
        }
        let identity = TunnelIdentity(id: payload.id, name: name, createdAt: payload.createdAt, isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
        faultVault.readAnswers = [payload.id: .answers(.config(payload))]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.readAllAnswer = .answers(.configs([payload]))
        faultVault.storeAnswer = .answers(.done)
        // Held open: this is the window between the entry going and the
        // payload going, and it is the window a restore can land in.
        faultVault.deleteAnswer = .answersAfter(seconds: 2, .done)

        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == payload.id }) else {
            fail("side manager did not materialize the tunnel")
            return
        }

        let removal = Task { () -> Bool in
            do {
                try await manager.remove(tunnel: container)
                return true
            } catch {
                return false
            }
        }
        // The delete ledger is the signal: the id appears there before
        // the answer is waited out, so seeing it means the entry is
        // already gone and the removal is inside its payload delete.
        var waited = 0.0
        while !faultVault.deletedIds.contains(payload.id), waited < 3 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        guard faultVault.deletedIds.contains(payload.id) else {
            skip("environment: the removal never reached its payload delete")
            _ = await removal.value
            return
        }
        // NOT an environment exit. The two facts are separated by no
        // slack at all: the fake clears `entryExists` synchronously
        // before it answers, and `remove()` awaits that answer to
        // completion before it issues the delete this loop just saw. So
        // a delete on the ledger with the entry still standing means one
        // thing only — the entry-first order is gone. Same reasoning as
        // the arrangement guard below, which round 1 made a failure for
        // exactly this reason.
        guard !fake.entryExists else {
            fail("the payload delete was issued while the entry was still there — the entry-first order is gone")
            _ = await removal.value
            return
        }

        // The list alignment the entry's removal would have caused in
        // production, and ONLY that: `prune()` ingests without
        // reconciling, which is exactly why it exists. `refresh()` would
        // have run a reconcile of its own here — the very pass whose bar
        // this step exists to measure — so a reverted bar would have
        // been committed by the step's own arrangement, and the step
        // would then have found the id back on the list and failed on
        // its own arrangement rather than on the bar — the guard below
        // is a `fail`, so the broken promise would have been reported
        // as "the window never opened", which is the wrong sentence for
        // a deleted doctrine.
        await manager.prune()
        guard !manager.tunnels.contains(where: { $0.id == payload.id }) else {
            fail("the row survived an ingest taken after its entry was removed — the arrangement never opened the window")
            _ = await removal.value
            return
        }

        let restored = await manager.reconcileFromVault()
        check(restored == 0,
              "no entry was minted for a payload whose tunnel is being removed — restored=\(restored)")
        check(!manager.tunnels.contains(where: { $0.id == payload.id }),
              "and nothing came back to the list under that id")

        let finished = await removal.value
        check(finished, "with the removal itself finishing on its own terms")
        // No closing list check here, deliberately. One used to stand at
        // this line and it could not fail: whatever the bar does, the
        // removal completes right above and retires the row BY ID, so a
        // re-minted container is evicted with the original and the list
        // reads empty in both worlds. The two checks above are the seal;
        // a third that no mutation can redden is decoration.
    }

    /// A removal that cannot take the entry hands the row back to the
    /// system, and leaves the tunnel standing but DISARMED.
    ///
    /// Two claims, one arrangement, because they are two halves of the
    /// same failure. `remove()` stands the recovery rule down before it
    /// touches the entry, so a refused `removePreferences` returns a
    /// tunnel whose stores are both intact and whose rule is off — the
    /// price the order pays knowingly, and the thing the user is NOT
    /// told. And the row it returns is repainted from the system rather
    /// than left wearing the value the manager last wrote, which matters
    /// because the values it can be wearing are terminal.
    ///
    /// The disagreement is arranged directly rather than by running the
    /// ladder that produces it in the field. An exhausted ladder grounds
    /// a row FLAT to `.inactive` over a session the system still holds
    /// at `.connecting`, and reports nothing further — so the row reads
    /// idle, Delete is offered, the delete flow skips the stop, and
    /// `startDeactivation` would refuse on the row's own reading. That
    /// state is exactly "provider connecting, row inactive, no
    /// notification pending", which is what the two lines below build.
    ///
    /// Which guard answers first, said exactly: `isManagerDriven`, and
    /// it answers false on the row's `.inactive` STATUS alone. The
    /// intent withdrawal the removal performs above the derive is NOT
    /// what opens the gate here and this step does not measure it —
    /// that would need an `.activating` row under a live attempt, which
    /// this rig never builds. The gate's lowering clause cannot refuse
    /// the derive either, since `.connecting` maps to a RISING value.
    /// What the step does rest on: `observesSystemChanges: false` keeps
    /// a reload from repainting the row instead, and `setStatusSilently`
    /// posts nothing — so if the hand-back is removed, nothing else in
    /// this rig can raise the row and the check goes red.
    func aRefusedEntryRemovalHandsTheRowBack() async {
        let name = "TE-Remove-HandBack-\(runTag)"
        guard let payload = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the hand-back config")
            return
        }
        let identity = TunnelIdentity(id: payload.id, name: name, createdAt: payload.createdAt, isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)
        // Armed and inactive: the resting state `remove()` calls NORMAL,
        // and the one whose rule only `remove()` can take down.
        fake.arrangeArmed()
        // The entry refuses to go. Nothing else in the engine drives
        // this answer, which is why the catch arm under test has never
        // been entered by a step before this one.
        fake.removeAnswer = .fails(NSError(domain: "TE.Vault", code: 61,
                                           userInfo: [NSLocalizedDescriptionKey: "entry removal refused"]))

        let faultVault = FaultVaultClient()
        faultVault.readAnswers = [payload.id: .answers(.config(payload))]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.readAllAnswer = .answers(.configs([payload]))
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let container = manager.tunnels.first(where: { $0.id == payload.id }) else {
            fail("side manager did not materialize the tunnel")
            return
        }

        // The row was born `.inactive` from a `.disconnected` provider;
        // moving the provider alone reproduces the ground the ladder
        // leaves, with no notification to correct it.
        fake.setStatusSilently(.connecting)
        guard container.status == .inactive else {
            fail("the arrangement never opened the window — the row reads \(container.status) rather than .inactive")
            return
        }
        let armedBefore = fake.storedOnDemand

        do {
            try await manager.remove(tunnel: container)
            fail("the removal reported success over an entry removal that was refused")
            return
        } catch {
            log("the removal refused to claim success — \(error.localizedDescription)")
        }

        check(fake.removeCount == 1 && fake.entryExists,
              "the entry was asked for and refused, so it is still there — removes=\(fake.removeCount), entryExists=\(fake.entryExists)")
        check(faultVault.deletedIds.isEmpty,
              "and the payload was never touched, because the entry goes first — deletes=\(faultVault.deletedIds.count), expected 0")
        check(container.status == .activating,
              "the row was handed back to the system's reading rather than left grounded flat over a live session (status=\(container.status))")
        check(armedBefore && !fake.storedOnDemand,
              "and the tunnel stands DISARMED: the rule came down before the entry was tried and nothing re-arms it (armedBefore=\(armedBefore), storedNow=\(fake.storedOnDemand))")
        check(manager.tunnels.contains(where: { $0.id == payload.id }),
              "with the tunnel still on the list, both stores whole, for the user to try again")
    }
}
#endif
