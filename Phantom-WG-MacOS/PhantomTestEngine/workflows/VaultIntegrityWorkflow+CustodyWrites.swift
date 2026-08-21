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
// Vault Integrity — Custody Writes
//
// Steps belonging to `VaultIntegrityWorkflow`; the registry lives in the
// main file. They ask which store a removal empties first, and what a
// removal that only half finishes leaves behind.
//
// The steps differ by what each one ARRANGES, and that is the taxonomy a
// new step should be placed into. No count is kept here on purpose: the
// count has been wrong twice, both times because a step was added without
// re-reading the header, and a taxonomy that silently stops covering the
// file is worse than none.
//
// The kinds:
//
//   - Fail one STORE and read which one the removal had already emptied.
//     An order is only visible in what survives when the second half does
//     not happen.
//   - Hold a SUCCESSFUL removal's window open instead, because the bar it
//     measures — the restore refusing to re-mint an entry being removed —
//     exists only while the removal is still running.
//   - Fail the ENTRY and then read the ROW rather than either store: drive
//     the removal into a world where row and system already disagree, and
//     ask what it hands back.
//   - Fail a store and then KEEP GOING, because the claim is not what the
//     failure left but what the process does about it afterwards.
//   - Read neither store: fail a write twice, each way a vault can fail,
//     and read what the USER is handed — the two failures give opposite
//     instructions and must not arrive under one sentence.
//   - Fail nothing and read WHICH ROW comes back: hold a creation open
//     inside its own append window, drive a reload into it, and ask
//     whether the list carries the id once or twice.
//   - Fail nothing and take the STORE: raise the uninstall latch and read
//     what a restore and a realign each do about it. Both arrange the
//     latch DURING a suspension, because a latch raised beforehand is
//     answered by an earlier guard and proves the wrong thing.
//   - Hold a REMOVAL open and run a teardown method into it.
//   - Drive the teardown's LAST step, the entry removal itself.

#if DEBUG
import Foundation
import NetworkExtension

// MARK: - Custody writes — which store a removal empties first, and
// what a removal that only half finishes leaves behind.
//
// The file holds TWELVE steps in nine kinds, and the difference is
// what each one arranges. The count is grepped, not remembered: this
// header has been wrong twice, both times because a step was added
// without re-reading it, and a taxonomy that silently stops covering
// the file is worse than none — a reader trusts it to say where a new
// step belongs.
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
//   - One fails a store and then keeps going, because the claim is not
//     what the failure left but what the process does about it
//     AFTERWARDS: the trailing pass that turns entry-first's residue
//     back into a whole tunnel.
//   - One reads neither store and neither row: it fails a write twice,
//     each way a vault can fail, and reads what the USER is handed. The
//     two failures give opposite instructions and were arriving under
//     one sentence, so the claim is that they now differ.
//   - One fails nothing at all and reads WHICH ROW comes back: it holds
//     a creation open inside its own append window, drives a reload
//     into it, and asks whether the list ends up carrying the id once
//     or twice.
//   - Two fail NOTHING and take the STORE instead: they raise the
//     uninstall latch and read what a restore and a realign each do
//     about it. Both must arrange the latch DURING a suspension,
//     because a latch raised beforehand is answered by an earlier guard
//     and proves the wrong thing.
//   - One holds a REMOVAL open and runs a teardown method into it: the
//     uninstall's disarm sweep, driven at a row whose entry a removal
//     has already taken. It raises no latch — the bar it measures is
//     the sweep's own liveness read, not the teardown's.
//   - One drives the teardown's LAST step — the entry removal itself —
//     and reads which entries it is allowed to take: the classified set
//     and nothing else, with no payload touched by it at all.
//
// The fault vault supplies the failures and the verdict that chooses
// the order; the providers are canned, so the entry side is observable
// too. Nothing reaches the real vault or the system's preferences — as
// in the sibling file, every surface is fabricated, including ones a
// step's own path should never touch. That last clause is the part
// worth re-reading when adding a step: a surface left `.real` because
// "this path never writes it" is a bet on the code under test still
// being correct, which is the one thing a step may not assume.
extension VaultIntegrityWorkflow {

    /// A vault that ANSWERS no and a vault that does not answer must not
    /// reach the user under one sentence.
    ///
    /// The two verdicts have been typed at the client since Ö3, and the
    /// CRUD paths still collapsed them: five sites compared `== .done`
    /// and threw the same `vaultUnavailable`, whose text tells the user
    /// to make sure the system extension is active and try again. That
    /// is sound advice for silence and the wrong advice for a refusal —
    /// the keychain answered, three times, and waiting changes nothing.
    ///
    /// The step drives `add`, which is the shortest path to the store,
    /// and it drives it TWICE because neither half alone can carry the
    /// claim: an assertion that a refusal says "refused" passes just as
    /// well when everything says "refused". What is being measured is a
    /// DIFFERENCE, so the closing check reads the two user-facing
    /// sentences against each other. Point both cases at one string and
    /// this is the line that reddens.
    ///
    /// Nothing shadows the measured line. `add` checks the name against
    /// an empty list, then runs the duplicate purge — whose bulk read is
    /// answered with an empty set here precisely so it passes rather
    /// than throwing a verdict of its own — and the very next thing it
    /// does is the store. The rollback delete is never reached: the
    /// store guard throws ahead of the `do` block that owns it.
    func aRefusedVaultWriteReadsDifferentlyFromASilentOne() async {
        let name = "TE-Add-Refusal-\(runTag)"
        guard let payload = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the refusal config")
            return
        }

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([]))
        faultVault.readAnswer = .answers(.missing)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: FakeSlotFactory(canned: []),
            vault: faultVault,
            observesSystemChanges: false
        )

        // HALF ONE — the vault answers no. Each half spends the whole
        // retry ladder (three attempts, 600ms then 1200ms apart), which
        // is production's patience and deliberately not shortened: the
        // refusal that reaches the user is the LAST attempt's, and a
        // step that skipped the ladder would be judging a verdict no
        // caller ever sees.
        faultVault.storeAnswer = .answers(.refused)
        guard let refusal = await failureFromAdd(manager, payload, "refused the write") else { return }
        if case .vaultRefused = refusal {
            check(true, "a vault that answered no reached the user as a refusal")
        } else {
            check(false, "a vault that answered no reached the user as \(refusal)")
        }

        // HALF TWO — the vault says nothing at all.
        faultVault.storeAnswer = .answers(.unreachable)
        guard let silence = await failureFromAdd(manager, payload, "never answered") else { return }
        if case .vaultUnavailable = silence {
            check(true, "and a vault that never answered reached the user as unavailable")
        } else {
            check(false, "a vault that never answered reached the user as \(silence)")
        }

        // The claim itself. Two cases that map to one string would pass
        // both checks above and fail here.
        let refusalText = refusal.errorDescription ?? ""
        let silenceText = silence.errorDescription ?? ""
        // The keys themselves are excluded, because a missing
        // translation resolves to the key and two DIFFERENT keys differ
        // just as happily as two different sentences — so without this
        // the string half of the fix would be unwitnessed and a dropped
        // entry in either JSON would still read green.
        check(refusalText != silenceText
              && refusalText != "error_vault_refused"
              && silenceText != "error_vault_unavailable",
              "so the two failures no longer arrive under one sentence, and both resolved to real copy"
              + " — refused=\"\(refusalText)\"")
        check(manager.tunnels.isEmpty,
              "and neither attempt left a row behind — rows=\(manager.tunnels.count), expected 0")
    }

    /// Runs `add` expecting it to fail, and hands back the management
    /// error it threw. `nil` means the step has already been failed
    /// here, with the sentence that actually fits what happened — and
    /// that is the whole reason this reports rather than returning a
    /// bare optional. Two different things end an `add` other than the
    /// verdict under test, a success and a foreign error type, and a
    /// caller that saw one `nil` for both would have to pick one
    /// sentence and be wrong about the other.
    ///
    /// `vaultSaid` names the arrangement, so the failure line says which
    /// half missed rather than making the reader count halves.
    private func failureFromAdd(
        _ manager: TunnelsManager,
        _ payload: TunnelConfig,
        _ vaultSaid: String
    ) async -> TunnelManagementError? {
        do {
            _ = try await manager.add(config: payload)
            fail("the add reported success over a vault that \(vaultSaid)")
            return nil
        } catch let error as TunnelManagementError {
            return error
        } catch {
            fail("the add left the management surface entirely over a vault that \(vaultSaid) — \(error)")
            return nil
        }
    }

    /// A creation whose entry the list took while it was suspended hands
    /// that row back rather than adding a second one for the same id.
    ///
    /// `createEntry` saves the configuration and then re-reads it, two
    /// suspensions, and from the first answer onwards the system HOLDS
    /// the entry while the list does not. An `ingest` landing there
    /// mirrors the system honestly and creates the row; the creation
    /// then appends its own, and the id is listed twice.
    ///
    /// The window is opened by holding the SECOND round-trip, not the
    /// first: the entry has to exist for the ingest to have anything to
    /// list, so a held save would arrange a world where nothing can go
    /// wrong. And it is opened through the minted provider's own
    /// answers, which is what the factory ledger is for — the object is
    /// created inside `createEntry`, three lines before the save, so
    /// there is no moment in which a step could configure it by hand.
    ///
    /// Both facts the arrangement rests on are MEASURED, not assumed:
    /// that the entry landed, and that the creation had not appended
    /// yet. A step that skipped either would report the same green while
    /// measuring a window that never opened.
    ///
    /// `prune()` drives the reload, not `refresh()`. A reconcile here
    /// would be a second path that creates entries, and the closing
    /// check — one row for this id — could then be true because the
    /// restore had been barred rather than because the creation yielded.
    func createEntryYieldsToARowTheListAlreadyTook() async {
        let name = "TE-Add-Window-\(runTag)"
        guard let payload = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the append-window config")
            return
        }

        let faultVault = FaultVaultClient()
        // The ownership answer, so the ingest keeps the minted entry
        // rather than reading it as another user's.
        faultVault.readAllAnswer = .answers(.configs([payload]))
        faultVault.readAnswers = [payload.id: .answers(.config(payload))]
        faultVault.readAnswer = .answers(.missing)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let factory = FakeSlotFactory(canned: [])
        factory.minted.loadAnswer = .succeedsAfter(seconds: 1.5)

        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: factory,
            vault: faultVault,
            observesSystemChanges: false
        )

        // The outcome is CAPTURED rather than discarded with `try?`. A
        // thrown add and a slow one are different worlds, and the skip
        // arm below reads the same in both — so an add that failed for a
        // reason this step never anticipated would have been reported as
        // an environment timeout, which is the sentence a broken rig
        // hides behind.
        let creation = Task { @MainActor in try await manager.add(config: payload) }

        var waited = 0.0
        while factory.minted.last?.entryExists != true, waited < 3 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        guard factory.minted.last?.entryExists == true else {
            if case .failure(let error) = await creation.result {
                fail("the creation threw instead of landing its entry — \(error.localizedDescription)")
            } else {
                skip("environment: the creation never landed its entry inside the budget")
            }
            return
        }
        guard !manager.tunnels.contains(where: { $0.id == payload.id }) else {
            skip("environment: the creation appended before the reload could be driven")
            _ = await creation.result
            return
        }

        await manager.prune()
        guard let ingested = manager.tunnels.first(where: { $0.id == payload.id }) else {
            fail("the ingest did not list an entry the system already held — the window was never opened")
            _ = await creation.result
            return
        }

        guard case .success(let created) = await creation.result else {
            fail("the creation threw after its entry had already landed — the window it opened was left half open")
            return
        }
        check(manager.tunnels.filter { $0.id == payload.id }.count == 1,
              "the id is on the list exactly once once the creation finished —"
              + " rows=\(manager.tunnels.filter { $0.id == payload.id }.count), expected 1")
        check(created === ingested,
              "and the creation handed back the row the list already held, rather than a second container"
              + " describing the same entry (waited \(String(format: "%.1f", waited))s)")
    }

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

        // The repair half is NOT measured here, and deliberately so:
        // the row is never evicted on this path, so any "wait for the
        // tunnel to come back" written into this step would be answered
        // by a row that never left. The sibling step below arranges the
        // eviction first and measures it properly.
    }

    /// A teardown that has taken the store stops the restore from
    /// minting into it — both before the pass starts and once it is
    /// already running.
    ///
    /// The uninstall flow classifies which entries it may remove while
    /// the vault still answers, and then removes exactly that set with
    /// the extensions down. Every entry a reconcile mints after that
    /// classification carries an id the classification never saw, so
    /// the removal step skips it and the flow reports a clean uninstall
    /// over a row still sitting in System Settings. Barring the
    /// SCHEDULER was never enough for this: the pass that matters is
    /// the one already in flight, which was admitted before the latch
    /// went up and then suspends on a system read, an ingest, a probe
    /// per candidate and two round-trips behind each.
    ///
    /// The flow itself cannot be driven from here — it deactivates the
    /// extensions this engine is talking to — so this step isolates the
    /// half that can be: the latch, and what the restore does about it.
    ///
    /// Three halves, and the first exists to make the others mean
    /// something. Half one mints with the latch DOWN, which is what
    /// proves the arrangement really produces a candidate that would
    /// otherwise be created; without it, "nothing was minted" is a
    /// sentence a broken rig prints just as happily.
    func aTeardownThatTookTheStoreStopsTheRestore() async {
        let first = "TE-Latch-Control-\(runTag)"
        let second = "TE-Latch-Barred-\(runTag)"
        guard var control = TestConfigFactory.throwaway(name: first),
              var barred = TestConfigFactory.throwaway(name: second) else {
            fail("could not build the latch configs")
            return
        }
        // Candidate order is by `createdAt`, and this step's whole
        // claim is about WHICH candidate got through, so the order is
        // pinned rather than inherited from clock resolution.
        control.createdAt = Date(timeIntervalSince1970: 1_000_000)
        barred.createdAt = Date(timeIntervalSince1970: 1_000_100)

        let faultVault = FaultVaultClient()
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)
        faultVault.readAllAnswer = .answers(.configs([control]))
        faultVault.readAnswers = [control.id: .answers(.config(control))]

        // An empty system list, so both payloads read as entries the
        // system has lost — which is exactly what makes them candidates.
        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: FakeSlotFactory(canned: []),
            vault: faultVault,
            observesSystemChanges: false
        )

        // HALF ONE — the control. Latch down, so the pass mints.
        await manager.refresh()
        guard manager.tunnels.contains(where: { $0.id == control.id }) else {
            fail("the arrangement never produced a mintable candidate — a restore with the latch DOWN created nothing,"
                 + " so the bar below would prove nothing")
            return
        }
        check(manager.tunnels.count == 1,
              "with the latch down the restore minted the entry the system had lost — rows=\(manager.tunnels.count), expected 1")

        // HALF TWO — the latch is up BEFORE the pass starts, which is
        // the guard in `reload` ahead of the reconcile.
        faultVault.readAllAnswer = .answers(.configs([control, barred]))
        faultVault.readAnswers[barred.id] = .answers(.config(barred))
        manager.suspendRefreshForUninstall()

        await manager.refresh()

        // The claim is the OUTCOME, and deliberately not a guard. Three
        // checks stand between a raised latch and a minted entry on THIS
        // path — the scheduler's, `reload`'s before the reconcile, and
        // the mint loop's own; the scheduler's is the one this
        // arrangement never routes through — and this arrangement raises the latch BEFORE the
        // pass, so the first one it meets answers and the others are
        // never consulted. Naming any single guard in this sentence
        // would be crediting a line the step cannot separate from its
        // neighbours; that separation is half three's whole job, and the
        // mint loop's own check is witnessed there and nowhere else.
        check(!manager.tunnels.contains(where: { $0.id == barred.id }),
              "a teardown holding the store got no new entry minted under it, whichever of its checks answered first")
        // One row, and it is the one the system already holds. The count
        // is what carries the claim: `barred` is the only candidate this
        // pass has — the control's entry landed with its mint and the
        // fake system list answers with it now (44d) — so a reverted bar
        // mints it and the count reads two. The named check above says
        // WHICH row is missing; this one says nothing else arrived in
        // its place.
        //
        // What this does NOT read is `ingest`'s narrowing. A surviving
        // control row is ingest agreeing with a system list that still
        // holds the entry, which is the case where narrowing has
        // nothing to do — so it is evidence that ingest ran, not that
        // it narrows while a teardown holds the store. That claim needs
        // a row whose entry has GONE under a raised latch, and this rig
        // does not build one. Naming it here rather than implying it:
        // an earlier version of this comment read as if the surviving
        // row proved the unbarred-ingest sentence, and it does not.
        check(manager.tunnels.count == 1 && manager.tunnels.contains(where: { $0.id == control.id }),
              "and nothing arrived beside the row the system already holds — rows=\(manager.tunnels.count), expected 1")

        // HALF THREE — the one the package exists for, and the one the
        // two halves above CANNOT reach. Both of them raise the latch
        // before the pass, so `reload`'s guard answers and returns;
        // whatever the mint loop does is never consulted. The claim
        // that "the pass that matters is the one already in flight"
        // needs the latch to go up while the pass is SUSPENDED.
        //
        // So the bulk read is held open and the store is taken during
        // it — and the pass is entered through `reconcileFromVault`
        // DIRECTLY rather than through `refresh()`.
        //
        // That is not a shortcut, it is the arrangement. Going through
        // `refresh()` puts `reload`'s own guard on the path, and a
        // green result then cannot say which guard answered: "nothing
        // was minted" reads the same whether the mint loop stood down
        // or the pass never reached it. Entering here removes that
        // guard from the path entirely, so the only thing left that can
        // return zero is the per-candidate re-read inside the loop —
        // and the count comes back as a NUMBER rather than as an
        // absence to be inferred from the list.
        // Released through the flow's own door, not the gate's:
        // An earlier version called a gate-side resume here; it was
        // refused while the teardown held the store, so the latch
        // stayed UP, the mid-pass raise below was inert, and this half
        // was a second copy of the one above. The live run said so by
        // omission: the mint loop's own bail line never printed.
        manager.releaseStoreAfterUninstall()
        // And the arrangement is PROVEN rather than assumed. A leaked
        // latch produces exactly the same three greens as the window
        // this half means to open, so without this the step could pass
        // while measuring the wrong thing — which it did.
        guard !manager.isStoreHeldForTeardown else {
            fail("the arrangement leaked a latch from the half above — the mid-pass window was never opened")
            return
        }
        faultVault.readAllAnswer = .answersAfter(seconds: 1.5, .configs([control, barred]))
        let probesBefore = faultVault.readIds.count
        // Read rather than assumed to be zero. This half enters
        // `reconcileFromVault` directly, so no ingest runs on this path
        // and the list arrives carrying whatever the half above left in
        // it — today the control row, whose entry the mint put into the
        // system list. An absolute count here would be measuring that
        // inheritance instead of this pass.
        let rowsBefore = manager.tunnels.count

        let pass = Task { @MainActor in await manager.reconcileFromVault() }
        try? await Task.sleep(for: .milliseconds(400))
        manager.suspendRefreshForUninstall()
        let restored = await pass.value

        check(restored == 0,
              "a teardown that took the store MID-PASS got nothing minted under it — restored=\(restored), expected 0")
        check(manager.tunnels.count == rowsBefore && !manager.tunnels.contains(where: { $0.id == barred.id }),
              "and no row was added for the candidate it stood down on — rows=\(manager.tunnels.count),"
              + " unchanged from \(rowsBefore)")
        // The sharper reading, and what separates this half from the
        // two above: the loop stood down BEFORE it spent a probe on its
        // first candidate. A pass that had reached its minting would
        // have read at least one payload by id.
        check(faultVault.readIds.count == probesBefore,
              "and it stood down before spending a probe on its first candidate — probes=\(faultVault.readIds.count), unchanged from \(probesBefore)")
    }

    /// The uninstall's last step removes the classified entries and
    /// nothing else.
    ///
    /// It is the only step of the flow that deletes anything from the
    /// system store, it runs with the extensions already down, and it
    /// works off a set computed minutes earlier — so what it must never
    /// do is act on an id that set does not name. A custody row's entry
    /// is the obvious one: it is deliberately excluded upstream because
    /// an undecodable payload has no other anchor, and taking it here
    /// would destroy the one thing a reinstall could rescue it from.
    ///
    /// The flow also PRINTS an accounting for the rows it walks past,
    /// and this step does not read it — nothing here can, because that
    /// count lives only in a log line. It is named rather than claimed:
    /// on a sound run those rows are another user's entries or our own
    /// custody rows, and the same line is what a latch failure would
    /// surface, which is why the production side logs instead of
    /// skipping silently. Turning it into an assertion needs a counter
    /// the manager does not expose yet.
    func theUninstallRemovalTakesOnlyTheClassifiedEntries() async {
        let removableName = "TE-Uninstall-Removable-\(runTag)"
        let keptName = "TE-Uninstall-Kept-\(runTag)"
        let removableId = UUID()
        let keptId = UUID()
        let removable = FakeSlotProvider(
            name: removableName,
            identity: TunnelIdentity(id: removableId, name: removableName, createdAt: Date(), isGhost: false),
            status: .disconnected)
        let kept = FakeSlotProvider(
            name: keptName,
            identity: TunnelIdentity(id: keptId, name: keptName, createdAt: Date(), isGhost: false),
            status: .disconnected)

        let faultVault = FaultVaultClient()
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.readAllAnswer = .answers(.configs([]))
        // Fabricated even though this path writes neither: an unset
        // surface forwards to the user's REAL vault, so leaving them
        // `.real` would make the closing check — no payload deleted —
        // into a bet that the code under test is already correct. If it
        // ever were not, the step would prove the defect by destroying
        // a real secret.
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [removable, kept],
            providerFactory: FakeSlotFactory(canned: [removable, kept]),
            vault: faultVault,
            observesSystemChanges: false
        )

        // Only one id is classified removable — the other stands for a
        // custody row, or another user's entry.
        await manager.removeEntriesForUninstall([removableId])

        check(removable.removeCount == 1 && !removable.entryExists,
              "the classified entry left the system store — removes=\(removable.removeCount), entryExists=\(removable.entryExists)")
        // `removeCount == 0` alone: nothing else in this rig can clear
        // that entry, so an `entryExists` conjunct beside it cannot go
        // red on its own and would only restate the count.
        check(kept.removeCount == 0,
              "and the one outside the set was not touched — removes=\(kept.removeCount), expected 0")
        // Read the SET, not the list: the flow acts off a fresh system
        // read, so a row still in the mirror proves nothing about what
        // the store now holds.
        check(faultVault.deletedIds.isEmpty,
              "with no payload deleted by this step at all — the flow removes entries and never secrets (deletes=\(faultVault.deletedIds.count))")
    }

    /// The uninstall's disarm sweep does not write to a row a removal
    /// is taking.
    ///
    /// This is the one the stage review found, and it lived BETWEEN two
    /// packages rather than inside either: the sweep saves to every
    /// listed row, the entry-first order keeps a row listed for the
    /// whole payload-delete ladder AFTER its entry is gone, and a save
    /// landing there re-mints the entry the removal just took. The
    /// result is an entry with no payload — hidden by the ownership
    /// boundary, undeletable from the app, and left in System Settings
    /// if the teardown then throws before its own removal step.
    ///
    /// The arrangement is the window itself: the payload delete is held
    /// open, so the removal is parked with its entry gone and its row
    /// still listed, and the sweep runs into exactly that.
    func theUninstallSweepDoesNotWriteToARowBeingRemoved() async {
        let name = "TE-Sweep-Removing-\(runTag)"
        guard let payload = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the sweep config")
            return
        }
        let identity = TunnelIdentity(id: payload.id, name: name, createdAt: payload.createdAt, isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)
        fake.arrangeArmed()

        let faultVault = FaultVaultClient()
        faultVault.readAnswers = [payload.id: .answers(.config(payload))]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.readAllAnswer = .answers(.configs([payload]))
        faultVault.storeAnswer = .answers(.done)
        // Held open: this is the stretch where the entry is already
        // gone and the row is still listed.
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

        let removal = Task { @MainActor in (try? await manager.remove(tunnel: container)) != nil }
        // The delete ledger is the signal that the entry has gone and
        // the payload delete is in flight.
        var waited = 0.0
        while !faultVault.deletedIds.contains(payload.id), waited < 3 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        guard faultVault.deletedIds.contains(payload.id), !fake.entryExists else {
            fail("the arrangement never opened the window — the removal did not reach its payload delete with the entry gone")
            _ = await removal.value
            return
        }
        let savesBefore = fake.saveCount

        await manager.disarmAllRecovery()

        check(fake.saveCount == savesBefore,
              "the sweep issued no save for a row being removed — saves=\(fake.saveCount), unchanged from \(savesBefore)")
        check(!fake.entryExists,
              "so the entry the removal took stayed gone rather than being written back (entryExists=\(fake.entryExists))")
        _ = await removal.value
    }

    /// The realign half stands down mid-walk when a teardown takes the
    /// store, which is a separate claim from the minting half's.
    ///
    /// Realign is the pass's OTHER writer: it saves identity onto
    /// entries that already exist. Under an uninstall that is the
    /// sharper of the two — the teardown is removing those very
    /// entries, and a save landing behind a removal re-mints what it
    /// just took. A guard at the call site only bars a realign that has
    /// not begun; this one has to bar the rest of a walk already in
    /// progress, because each row costs a system round-trip and a long
    /// list gives a teardown ample room to arrive part-way down it.
    ///
    /// Two drifted rows, and the first one's save answers slowly. The
    /// store is taken while that save is in flight, so the first row is
    /// realigned and the second must not be. Anything that stopped the
    /// walk earlier would leave the FIRST row stale too, which is what
    /// tells this apart from a pass that never ran.
    func realignStandsDownWhenATeardownTakesTheStore() async {
        let firstName = "TE-Realign-Ahead-\(runTag)"
        let secondName = "TE-Realign-Behind-\(runTag)"
        guard var ahead = TestConfigFactory.throwaway(name: firstName),
              var behind = TestConfigFactory.throwaway(name: secondName) else {
            fail("could not build the realign configs")
            return
        }
        ahead.createdAt = Date(timeIntervalSince1970: 2_000_000)
        behind.createdAt = Date(timeIntervalSince1970: 2_000_100)

        // Both rows are LISTED, so neither is a mint candidate and the
        // pass goes straight to its realign half. Both projections
        // carry a stale name, which is what realign exists to repair.
        let staleAhead = TunnelIdentity(id: ahead.id, name: firstName + "-stale",
                                        createdAt: ahead.createdAt, isGhost: false)
        let staleBehind = TunnelIdentity(id: behind.id, name: secondName + "-stale",
                                         createdAt: behind.createdAt, isGhost: false)
        let fakeAhead = FakeSlotProvider(name: staleAhead.name, identity: staleAhead, status: .disconnected)
        let fakeBehind = FakeSlotProvider(name: staleBehind.name, identity: staleBehind, status: .disconnected)

        let faultVault = FaultVaultClient()
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)
        faultVault.readAllAnswer = .answers(.configs([ahead, behind]))

        let manager = TunnelsManager(
            tunnelProviders: [fakeAhead, fakeBehind],
            providerFactory: FakeSlotFactory(canned: [fakeAhead, fakeBehind]),
            vault: faultVault,
            observesSystemChanges: false
        )

        // The row ahead answers its save slowly; that suspension is the
        // window the teardown arrives in.
        fakeAhead.saveAnswer = .succeedsAfter(seconds: 1.5)

        let pass = Task { @MainActor in await manager.refresh() }
        try? await Task.sleep(for: .milliseconds(400))
        manager.suspendRefreshForUninstall()
        await pass.value

        check(fakeAhead.saveCount == 1,
              "the row ahead of the teardown was realigned — saves=\(fakeAhead.saveCount), expected 1")
        check(fakeBehind.saveCount == 0,
              "and the row behind it was not written at all once the store was taken — saves=\(fakeBehind.saveCount), expected 0")
        check(fakeBehind.tunnelIdentity?.name == staleBehind.name,
              "so its projection still carries the stale name the teardown will remove it under"
              + " — name=\(fakeBehind.tunnelIdentity?.name ?? "nil")")
    }

    /// The residue entry-first accepts is the one the restore repairs,
    /// and this is the step that makes the repair a measurement rather
    /// than a promise.
    ///
    /// `remove()` schedules one trailing pass when its payload delete
    /// fails, because the configuration change its own entry removal
    /// broadcast was consumed by a reload that ran while the removal
    /// latch was still up — correctly barred, since a re-mint then
    /// would have raced the delete. Nothing else is due to fire. Delete
    /// that one line and every other custody step stays green while the
    /// entire argument for entry-first quietly stops being true.
    ///
    /// Two things make this measurable, and both are the shape an
    /// earlier attempt got wrong:
    ///
    /// The row must be DROPPED first. It is not evicted by the failed
    /// removal — that is the sibling step's subject — so a poll written
    /// without this would be waiting for something already there. The
    /// drop is taken with `prune()`, the ingest that does NOT reconcile,
    /// because the pass being measured IS a reconcile: arranging it with
    /// `refresh()` would have this step's own setup perform the repair
    /// it is checking for.
    ///
    /// And the return must be proven by IDENTITY, not by presence. A
    /// restore mints a fresh provider from the factory and wraps it in a
    /// new container; the planted fake is never revived. So a row under
    /// the same id is only proof if it is a DIFFERENT object from the
    /// one the removal was called on.
    func aFailedPayloadDeleteLeavesATunnelTheRestorePutsBack() async {
        let name = "TE-Remove-Restored-\(runTag)"
        guard let payload = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the restore config")
            return
        }
        let identity = TunnelIdentity(id: payload.id, name: name, createdAt: payload.createdAt, isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
        faultVault.readAnswers = [payload.id: .answers(.config(payload))]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.readAllAnswer = .answers(.configs([payload]))
        faultVault.storeAnswer = .answers(.done)
        // The payload delete fails, which is the only shape that
        // schedules the trailing pass.
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

        // The eviction the failed removal deliberately does not perform.
        // `prune()` and not `refresh()`: the restore is the subject, so
        // the arrangement must not run one.
        await manager.prune()
        guard !manager.tunnels.contains(where: { $0.id == payload.id }) else {
            fail("the row survived an ingest taken after its entry was removed — the arrangement never opened the window")
            return
        }

        // Now the only thing that can bring it back is the pass the
        // removal scheduled on its way out. The wait is the 400ms
        // debounce plus the pass itself.
        var waited = 0.0
        while !manager.tunnels.contains(where: { $0.id == payload.id }), waited < 3 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        guard let restored = manager.tunnels.first(where: { $0.id == payload.id }) else {
            fail("the payload outlived its entry with nothing scheduled to repair it — the trailing pass never ran (waited \(String(format: "%.1f", waited))s)")
            return
        }

        check(restored !== container,
              "the tunnel came back on a NEW container, so a restore built it rather than the old row never leaving (waited \(String(format: "%.1f", waited))s)")
        check(restored.name == name,
              "and it carries the name its surviving payload holds — name=\(restored.name), expected \(name)")
        check(!fake.entryExists,
              "on an entry the restore minted, not the one the removal took — the planted provider stays removed (plantedEntryExists=\(fake.entryExists))")
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
        // No `entryExists` check here, and the omission is the point:
        // an entry is only ever taken by `removePreferences`, so
        // `removeCount == 0` above already settles that the anchor is
        // still there. A second line asserting it would read like a
        // separate proof while being the same fact worded twice — the
        // shape this file has had to remove three times now.
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
