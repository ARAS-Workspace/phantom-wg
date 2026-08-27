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
// Vault Integrity — The Uninstall: What It Takes And What Must Not Undo It
//
// Steps belonging to `VaultIntegrityWorkflow`; the registry lives in the
// main file. Not to be confused with `+Teardown.swift`, which holds this
// workflow's own cleanup ARMS. The teardown here is the user's uninstall.
//
// It removes ENTRIES and keeps SECRETS on purpose, so a reinstall can
// restore them — and therefore leaves behind exactly the arrangement the
// restore was built to act on. Two mechanisms hold that apart, and they
// are deliberately NOT the same flag:
//
//   The refresh latch owns the uninstall's own window and is given back on
//   every exit, because a process that keeps it can never ingest, restore
//   or realign again.
//
//   The restore bar outlives that window. It stands only where it is
//   earned — a process that took no entry never raises it — and nothing
//   lowers it afterwards, because every door that could is a door the
//   extensions can come back through while their providers are still
//   resident.
//
// Scenarios:
//
//   A — A Teardown That Took The Store Stops The Restore
//   B — The Uninstall Removal Takes Only The Classified Entries
//   C — The Uninstall's Removal Is Not Undone By The Restore
//   D — A Teardown That Takes No Entry Leaves The Restore Alone
//       Three ways to take nothing: the system list never loads, nothing
//       classifies as removable, every removal is refused.
//   E — The Extensions Coming Back Does Not Lower The Teardown's Bar
//       The asymmetry above, driven: one door, two flags, only one of
//       them comes down.
//   F — The Uninstall Sweep Does Not Write To A Row Being Removed
//   G — Realign Stands Down When A Teardown Takes The Store
//
// What these cannot prove is the uninstall as the user runs it: the flow
// destroys the environment a run needs, so the steps drive its pieces over
// side managers rather than the flow itself.

#if DEBUG
import Foundation

extension VaultIntegrityWorkflow {

    func aTeardownThatTookTheStoreStopsTheRestore() async {
        let first = "TE-Latch-Control-\(runTag)"
        let second = "TE-Latch-Barred-\(runTag)"
        guard var control = TestConfigFactory.throwaway(name: first),
              var barred = TestConfigFactory.throwaway(name: second) else {
            fail("could not build the latch configs")
            return
        }
        control.createdAt = Date(timeIntervalSince1970: 1_000_000)
        barred.createdAt = Date(timeIntervalSince1970: 1_000_100)

        let faultVault = FaultVaultClient()
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)
        faultVault.readAllAnswer = .answers(.configs([control]))
        faultVault.readAnswers = [control.id: .answers(.config(control))]

        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: FakeSlotFactory(canned: []),
            vault: faultVault,
            observesSystemChanges: false
        )

        await manager.refresh()
        guard manager.tunnels.contains(where: { $0.id == control.id }) else {
            fail("the arrangement never produced a mintable candidate — a restore with the latch DOWN created nothing,"
                 + " so the bar below would prove nothing")
            return
        }
        check(manager.tunnels.count == 1,
              "with the latch down the restore minted the entry the system had lost — rows=\(manager.tunnels.count), expected 1")

        faultVault.readAllAnswer = .answers(.configs([control, barred]))
        faultVault.readAnswers[barred.id] = .answers(.config(barred))
        manager.suspendRefreshForUninstall()

        await manager.refresh()

        check(!manager.tunnels.contains(where: { $0.id == barred.id }),
              "a teardown holding the store got no new entry minted under it, whichever of its checks answered first")
        check(manager.tunnels.count == 1 && manager.tunnels.contains(where: { $0.id == control.id }),
              "and nothing arrived beside the row the system already holds — rows=\(manager.tunnels.count), expected 1")

        manager.releaseStoreAfterUninstall()
        guard !manager.isStoreHeldForTeardown else {
            fail("the arrangement leaked a latch from the half above — the mid-pass window was never opened")
            return
        }
        faultVault.readAllAnswer = .answersAfter(seconds: 1.5, .configs([control, barred]))
        let probesBefore = faultVault.readIds.count
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
        check(faultVault.readIds.count == probesBefore,
              "and it stood down before spending a probe on its first candidate — probes=\(faultVault.readIds.count), unchanged from \(probesBefore)")
    }

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
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [removable, kept],
            providerFactory: FakeSlotFactory(canned: [removable, kept]),
            vault: faultVault,
            observesSystemChanges: false
        )

        await manager.removeEntriesForUninstall([removableId])

        check(removable.removeCount == 1 && !removable.entryExists,
              "the classified entry left the system store — removes=\(removable.removeCount), entryExists=\(removable.entryExists)")
        check(kept.removeCount == 0,
              "and the one outside the set was not touched — removes=\(kept.removeCount), expected 0")
        check(faultVault.deletedIds.isEmpty,
              "with no payload deleted by this step at all — the flow removes entries and never secrets (deletes=\(faultVault.deletedIds.count))")
    }

    func theUninstallsRemovalIsNotUndoneByTheRestore() async {
        let name = "TE-Uninstall-Undone-\(runTag)"
        guard let payload = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the uninstall config")
            return
        }
        let identity = TunnelIdentity(id: payload.id, name: name, createdAt: payload.createdAt, isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)

        func arrangedVault() -> FaultVaultClient {
            let vault = FaultVaultClient()
            vault.readAnswer = .answers(.config(payload))
            vault.readAnswers = [payload.id: .answers(.config(payload))]
            vault.readAllAnswer = .answers(.configs([payload]))
            vault.storeAnswer = .answers(.done)
            vault.deleteAnswer = .answers(.done)
            return vault
        }

        let controlVault = arrangedVault()
        let faultVault = arrangedVault()

        let control = TunnelsManager(
            tunnelProviders: [],
            providerFactory: FakeSlotFactory(canned: []),
            vault: controlVault,
            observesSystemChanges: false
        )
        await control.refresh()
        guard control.tunnels.contains(where: { $0.id == payload.id }) else {
            fail("the arrangement never produced a mintable candidate — a manager that never tore anything down"
                 + " minted nothing from this payload, so the bar below would prove nothing")
            return
        }
        check(control.tunnels.count == 1,
              "a manager with no teardown behind it mints this payload back — rows=\(control.tunnels.count), expected 1,"
              + " which is what the removal below has to survive")

        let factory = FakeSlotFactory(canned: [fake])
        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: factory,
            vault: faultVault,
            observesSystemChanges: false
        )
        guard manager.tunnels.contains(where: { $0.id == payload.id }) else {
            fail("side manager did not materialize the tunnel")
            return
        }

        manager.suspendRefreshForUninstall()
        let removable = await manager.removableEntryIds()
        guard removable.contains(payload.id) else {
            fail("the classification did not call this entry removable — the removal below would take nothing")
            return
        }
        await manager.removeEntriesForUninstall(removable)
        manager.releaseStoreAfterUninstall()

        check(fake.removeCount == 1 && !fake.entryExists,
              "the uninstall took the entry — removes=\(fake.removeCount), entryExists=\(fake.entryExists)")
        check(faultVault.deletedIds.isEmpty,
              "and left the secret behind, which is the whole reason a restore could put the entry back"
              + " (deletes=\(faultVault.deletedIds.count))")

        await manager.refresh()

        check(factory.minted.providers.isEmpty,
              "the restore minted no entry from the payload the uninstall left behind —"
              + " minted=\(factory.minted.providers.count), expected 0")
        check(manager.tunnels.isEmpty,
              "so the list the user is left with stays empty — rows=\(manager.tunnels.count), expected 0")
    }

    func aTeardownThatTakesNoEntryLeavesTheRestoreAlone() async {
        let name = "TE-Uninstall-Untouched-\(runTag)"
        guard let payload = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the untouched config")
            return
        }
        let identity = TunnelIdentity(id: payload.id, name: name, createdAt: payload.createdAt, isGhost: false)

        func arrangedVault() -> FaultVaultClient {
            let vault = FaultVaultClient()
            vault.readAnswer = .answers(.config(payload))
            vault.readAnswers = [payload.id: .answers(.config(payload))]
            vault.readAllAnswer = .answers(.configs([payload]))
            vault.storeAnswer = .answers(.done)
            vault.deleteAnswer = .answers(.done)
            return vault
        }

        let darkFake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)
        let darkFactory = FakeSlotFactory(
            canned: [darkFake],
            loadFailure: NSError(domain: "TE.Uninstall", code: 81,
                                 userInfo: [NSLocalizedDescriptionKey: "driven system list failure"]))
        let darkManager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: darkFactory,
            vault: arrangedVault(),
            observesSystemChanges: false
        )

        await darkManager.removeEntriesForUninstall([payload.id])
        guard check(darkFake.removeCount == 0 && darkFake.entryExists,
                    "a teardown whose system list would not load took NOTHING, though the id it was given is exactly"
                    + " the one that list holds — removes=\(darkFake.removeCount), expected 0") else { return }
        let darkRestored = await darkManager.reconcileFromVault()
        check(darkRestored == 1 && darkFactory.minted.providers.count == 1,
              "so the restore is left alone and still mints what the system has lost —"
              + " restored=\(darkRestored), minted=\(darkFactory.minted.providers.count), expected 1 and 1")

        let idleFake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)
        let idleFactory = FakeSlotFactory(canned: [idleFake])
        let idleManager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: idleFactory,
            vault: arrangedVault(),
            observesSystemChanges: false
        )

        await idleManager.removeEntriesForUninstall([UUID()])
        guard check(idleFake.removeCount == 0 && idleFake.entryExists,
                    "and a teardown whose list DID load but classified nothing as removable took nothing either —"
                    + " removes=\(idleFake.removeCount), expected 0") else { return }
        let idleRestored = await idleManager.reconcileFromVault()
        check(idleRestored == 1 && idleFactory.minted.providers.count == 1,
              "so that restore is left alone too — the bar belongs to entries actually taken, not to the flow having"
              + " been entered (restored=\(idleRestored), minted=\(idleFactory.minted.providers.count))")

        let refusedFake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)
        refusedFake.removeAnswer = .fails(NSError(domain: "TE.Uninstall", code: 82,
                                                  userInfo: [NSLocalizedDescriptionKey: "driven removal refusal"]))
        let refusedFactory = FakeSlotFactory(canned: [refusedFake])
        let refusedManager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: refusedFactory,
            vault: arrangedVault(),
            observesSystemChanges: false
        )

        await refusedManager.removeEntriesForUninstall([payload.id])
        guard check(refusedFake.removeCount == 1 && refusedFake.entryExists,
                    "and a teardown that ASKED for its entry and was refused reached the removal and still holds it —"
                    + " removes=\(refusedFake.removeCount), entryExists=\(refusedFake.entryExists)") else { return }
        let refusedRestored = await refusedManager.reconcileFromVault()
        check(refusedRestored == 1 && refusedFactory.minted.providers.count == 1,
              "so its restore is left alone as well — a bar raised for a removal that never landed is taken back down"
              + " (restored=\(refusedRestored), minted=\(refusedFactory.minted.providers.count))")
    }

    func theExtensionsComingBackDoesNotLowerTheTeardownsBar() async {
        let name = "TE-Uninstall-Returned-\(runTag)"
        guard let payload = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the returned config")
            return
        }
        let identity = TunnelIdentity(id: payload.id, name: name, createdAt: payload.createdAt, isGhost: false)
        let fake = FakeSlotProvider(name: name, identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
        faultVault.readAnswer = .answers(.config(payload))
        faultVault.readAnswers = [payload.id: .answers(.config(payload))]
        faultVault.readAllAnswer = .answers(.configs([payload]))
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let factory = FakeSlotFactory(canned: [fake])
        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: factory,
            vault: faultVault,
            observesSystemChanges: false
        )

        manager.suspendRefreshForUninstall()
        await manager.removeEntriesForUninstall([payload.id])
        guard check(fake.removeCount == 1 && !fake.entryExists,
                    "the teardown took its entry and kept the payload, which is the only thing the bar exists for"
                    + " — removes=\(fake.removeCount), entryExists=\(fake.entryExists)") else { return }

        let barred = await manager.reconcileFromVault()
        guard check(barred == 0 && factory.minted.providers.isEmpty,
                    "the bar is up: a restore mints nothing from the payload left behind —"
                    + " restored=\(barred), minted=\(factory.minted.providers.count)") else { return }

        guard check(manager.isStoreHeldForTeardown,
                    "and the refresh latch is still up, so the door below has something to open") else { return }
        manager.releaseAbandonedStoreLatch()
        guard check(!manager.isStoreHeldForTeardown,
                    "the extensions' return FIRED that door — the refresh latch came down with it, which is what"
                    + " makes the reading below a measurement rather than a door that did nothing") else { return }

        let stillBarred = await manager.reconcileFromVault()
        check(stillBarred == 0 && factory.minted.providers.isEmpty,
              "but the SAME door left the teardown's bar alone — the extensions coming back is not a reason to"
              + " re-mint entries this process took (restored=\(stillBarred),"
              + " minted=\(factory.minted.providers.count))")

        let mintedLate = await settle(within: 2) { !factory.minted.providers.isEmpty }
        check(!mintedLate,
              "nor did the refresh that door schedules on its own way out — the real trigger runs and mints"
              + " nothing either (minted=\(factory.minted.providers.count))")
    }

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

        let staleAhead = TunnelIdentity(id: ahead.id, name: firstName + "-stale",
                                        createdAt: ahead.createdAt, isGhost: false)
        let staleBehind = TunnelIdentity(id: behind.id, name: secondName + "-stale",
                                         createdAt: behind.createdAt, isGhost: false)
        let fakeAhead = FakeSlotProvider(name: staleAhead.name, identity: staleAhead, status: .disconnected)
        let fakeBehind = FakeSlotProvider(name: staleBehind.name, identity: staleBehind, status: .disconnected)

        let faultVault = FaultVaultClient()
        faultVault.readAnswer = .answers(.unreachable)
        // The realign proves every candidate fresh before writing; without
        // per-id answers the pass would stop on a dark vault before the row
        // ahead of the teardown ever took its write.
        faultVault.readAnswers = [
            ahead.id: .answers(.config(ahead)),
            behind.id: .answers(.config(behind)),
        ]
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)
        faultVault.readAllAnswer = .answers(.configs([ahead, behind]))

        let manager = TunnelsManager(
            tunnelProviders: [fakeAhead, fakeBehind],
            providerFactory: FakeSlotFactory(canned: [fakeAhead, fakeBehind]),
            vault: faultVault,
            observesSystemChanges: false
        )

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
}
#endif
