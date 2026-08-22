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
//     what a restore and a realign each do about it. Both take the store
//     MID-PASS, because a latch raised before the pass starts is answered
//     by the pass's own opening guard and proves the wrong thing.
//   - Hold a REMOVAL open and run a teardown method into it.
//   - Drive the teardown's LAST step, the entry removal itself.
//   - Fail neither store but take the removal's own custody READ away, and
//     read that it refused before touching either.

#if DEBUG
import Foundation
import NetworkExtension

// MARK: - Custody writes — which store a removal empties first, and
extension VaultIntegrityWorkflow {

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

        faultVault.storeAnswer = .answers(.refused)
        guard let refusal = await failureFromAdd(manager, payload, "refused the write") else { return }
        if case .vaultRefused = refusal {
            check(true, "a vault that answered no reached the user as a refusal")
        } else {
            check(false, "a vault that answered no reached the user as \(refusal)")
        }

        faultVault.storeAnswer = .answers(.unreachable)
        guard let silence = await failureFromAdd(manager, payload, "never answered") else { return }
        if case .vaultUnavailable = silence {
            check(true, "and a vault that never answered reached the user as unavailable")
        } else {
            check(false, "a vault that never answered reached the user as \(silence)")
        }

        let refusalText = refusal.errorDescription ?? ""
        let silenceText = silence.errorDescription ?? ""
        check(refusalText != silenceText
              && refusalText != "error_vault_refused"
              && silenceText != "error_vault_unavailable",
              "so the two failures no longer arrive under one sentence, and both resolved to real copy"
              + " — refused=\"\(refusalText)\"")
        check(manager.tunnels.isEmpty,
              "and neither attempt left a row behind — rows=\(manager.tunnels.count), expected 0")
    }

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

    func createEntryYieldsToARowTheListAlreadyTook() async {
        let name = "TE-Add-Window-\(runTag)"
        guard let payload = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the append-window config")
            return
        }

        let faultVault = FaultVaultClient()
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

    func removalTakesTheEntryFirst() async {
        let name = "TE-Remove-EntryFirst-\(runTag)"
        guard let payload = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the entry-first config")
            return
        }
        let identity = TunnelIdentity(id: payload.id, name: name, createdAt: payload.createdAt, isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
        faultVault.readAnswers = [payload.id: .answers(.config(payload))]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.readAllAnswer = .answers(.configs([payload]))
        faultVault.storeAnswer = .answers(.done)
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

    }

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

        await manager.prune()
        guard !manager.tunnels.contains(where: { $0.id == payload.id }) else {
            fail("the row survived an ingest taken after its entry was removed — the arrangement never opened the window")
            return
        }

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

    func removalKeepsACustodyRowsEntryUntilLast() async {
        let name = "TE-Remove-Custody-\(runTag)"
        let id = UUID()
        let identity = TunnelIdentity(id: id, name: name, createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
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

        check(faultVault.deletedIds.contains(id) && fake.removeCount == 0,
              "the payload delete went first for a row whose payload does not decode — issued with the entry still untouched")
        check(manager.tunnels.contains(where: { $0.id == id }),
              "with the row still on the list to be seen from")
    }

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
        guard !fake.entryExists else {
            fail("the payload delete was issued while the entry was still there — the entry-first order is gone")
            _ = await removal.value
            return
        }

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
    }

    func aRefusedEntryRemovalHandsTheRowBack() async {
        let name = "TE-Remove-HandBack-\(runTag)"
        guard let payload = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the hand-back config")
            return
        }
        let identity = TunnelIdentity(id: payload.id, name: name, createdAt: payload.createdAt, isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)
        fake.arrangeArmed()
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
