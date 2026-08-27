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
// Vault Integrity — Custody Reads
//
// Steps belonging to `VaultIntegrityWorkflow`; the registry lives in the
// main file. They ask what the app believes about a payload at the MOMENT
// it acts on it, as opposed to what a bulk answer said earlier.
//
// They run over a `FaultVaultClient` and side managers rather than the
// user's own list, because every claim here needs a vault whose answers
// can be made to disagree — with themselves between the bulk answer and
// the per-id one, with the list the app is holding, or with the clock, by
// staying out long enough for a second caller to arrive. The real vault
// cannot be asked to do any of that on purpose.
//
// Nothing they drive reaches the real vault or the system's preferences,
// so they plant nothing and need no teardown net.
//
// One caution that is the reason this file is careful rather than lucky:
// the fault client's default is to FORWARD. A surface left `.real` reaches
// the user's own vault. Every step therefore sets EVERY surface, including
// ones its own path should never touch, so a call the step did not
// anticipate answers a fabrication instead of a keychain.

#if DEBUG
import Foundation
import NetworkExtension

// MARK: - Custody reads — what the app believes about a payload at the
extension VaultIntegrityWorkflow {

    func purgeSparesAListedPayload() async {
        let listedId = UUID()
        let listedName = "TE-Purge-Listed-\(runTag)"
        let claimedName = "TE-Purge-Claimed-\(runTag)"
        let orphanName = "TE-Purge-Orphan-\(runTag)"
        let racedName = "TE-Purge-Raced-\(runTag)"

        guard var drifted = TestConfigFactory.throwaway(name: claimedName),
              let incoming = TestConfigFactory.throwaway(name: claimedName),
              let orphan = TestConfigFactory.throwaway(name: orphanName),
              let reuse = TestConfigFactory.throwaway(name: orphanName),
              let racer = TestConfigFactory.throwaway(name: racedName),
              let rival = TestConfigFactory.throwaway(name: racedName) else {
            fail("could not build the purge configs")
            return
        }
        drifted.id = listedId

        let identity = TunnelIdentity(id: listedId, name: listedName, createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: listedName, identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([drifted]))
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)
        faultVault.readAnswer = .answers(.unreachable)

        let manager = TunnelsManager(
            tunnelProviders: [fake],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard manager.tunnels.contains(where: { $0.id == listedId }) else {
            fail("side manager did not materialize the listed tunnel")
            return
        }

        do {
            _ = try await manager.add(config: incoming)
        } catch {
            fail("the import that runs the purge failed outright: \(error.localizedDescription)")
            return
        }

        check(faultVault.deletedIds.isEmpty,
              "the import dropped nothing: the listed tunnel's payload survives the name it had already been given — deletes=\(faultVault.deletedIds.count), expected 0")

        faultVault.readAllAnswer = .answers(.configs([orphan]))
        do {
            _ = try await manager.add(config: reuse)
        } catch {
            fail("the second import failed outright: \(error.localizedDescription)")
            return
        }
        check(faultVault.deletedIds == [orphan.id],
              "and a payload no list holds is still dropped when its name is reused — the bar spares the listed, not the purge")

        await purgeSparesAPayloadBeingCreated(on: manager, vault: faultVault, racer: racer, rival: rival)
    }

    private func purgeSparesAPayloadBeingCreated(
        on manager: TunnelsManager,
        vault faultVault: FaultVaultClient,
        racer: TunnelConfig,
        rival: TunnelConfig
    ) async {
        faultVault.readAllAnswer = .answers(.configs([]))
        faultVault.storeAnswer = .answersAfter(seconds: 2, .done)
        let racing = Task { () -> Error? in
            do {
                _ = try await manager.add(config: racer)
                return nil
            } catch {
                return error
            }
        }
        var waited = 0.0
        while !faultVault.storedIds.contains(racer.id), waited < 3 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        guard faultVault.storedIds.contains(racer.id) else {
            skip("environment: the first import never reached its vault write")
            _ = await racing.value
            return
        }
        guard !manager.tunnels.contains(where: { $0.id == racer.id }) else {
            skip("environment: the first import landed before its creation window could be driven")
            _ = await racing.value
            return
        }
        faultVault.storeAnswer = .answers(.done)
        faultVault.readAllAnswer = .answers(.configs([racer]))
        var rivalError: Error?
        do {
            _ = try await manager.add(config: rival)
        } catch {
            rivalError = error
        }
        check(!faultVault.deletedIds.contains(racer.id),
              "and a payload whose entry is still being created keeps its secret through a second import of the same name")
        let racerError = await racing.value
        // Two imports raced one name. The name re-read makes whoever LISTS
        // first the winner; the other is refused and rolls its own payload
        // back. The step pins that contract, not who wins the race.
        let racerLanded = racerError == nil
        let rivalLanded = rivalError == nil
        check(racerLanded != rivalLanded,
              "exactly one of the two same-name imports landed — racer=\(racerLanded), rival=\(rivalLanded)")
        let rows = manager.tunnels.filter { $0.name.caseInsensitiveCompare(racer.name) == .orderedSame }
        check(rows.count == 1,
              "and the name is on the list exactly once — rows=\(rows.count)")
        let winnerId = racerLanded ? racer.id : rival.id
        let loserId = racerLanded ? rival.id : racer.id
        check(!faultVault.deletedIds.contains(winnerId) && faultVault.deletedIds.contains(loserId),
              "the loser's own rollback took its payload back, and only its own — no orphan secret, no touch"
              + " on the winner's (winnerDeleted=\(faultVault.deletedIds.contains(winnerId)))")
        var refusedByName = false
        if let error = (racerLanded ? rivalError : racerError) as? TunnelManagementError,
           case .tunnelAlreadyExistsWithThatName = error { refusedByName = true }
        check(refusedByName,
              "and the loser was refused with the name clash the user can read, not a stand-in failure")
    }

    func reconcileProvesAPayloadBeforeMinting() async {
        guard var present = TestConfigFactory.throwaway(name: "TE-Mint-Present-\(runTag)"),
              var vanished = TestConfigFactory.throwaway(name: "TE-Mint-Vanished-\(runTag)") else {
            fail("could not build the reconcile configs")
            return
        }
        var renamed = present
        renamed.name = "TE-Mint-Renamed-\(runTag)"
        vanished.createdAt = Date(timeIntervalSince1970: 1_000_000)
        present.createdAt = Date(timeIntervalSince1970: 2_000_000)
        renamed.createdAt = present.createdAt

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([present, vanished]))
        faultVault.readAnswers = [
            present.id: .answers(.config(renamed)),
            vanished.id: .answers(.missing),
        ]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: FakeSlotFactory(canned: []),
            vault: faultVault,
            observesSystemChanges: false
        )

        let restored = await manager.reconcileFromVault()

        check(restored == 1, "the pass restored the payload that was really there — restored=\(restored), expected 1")
        check(!manager.tunnels.contains(where: { $0.id == vanished.id }),
              "the payload the snapshot still listed was NOT minted — no entry outlives its secret here")
        let minted = manager.tunnels.first(where: { $0.id == present.id })
        check(minted != nil, "and the tunnel the system had lost is back on the list")
        check(minted?.name == renamed.name,
              "born from the payload as it reads NOW, and still reading that way when the pass ends — name=\(minted?.name ?? "nil"), expected \(renamed.name)")
        check(faultVault.readIds.count == 2 && Set(faultVault.readIds) == Set([present.id, vanished.id]),
              "each candidate was proven on its own id, once — probes=\(faultVault.readIds.count), expected 2")
    }

    func reconcileMarksItsCandidateBeforeItAsks() async {
        let headName = "TE-Mint-Race-Head-\(runTag)"
        let queuedName = "TE-Mint-Race-Queued-\(runTag)"
        guard var head = TestConfigFactory.throwaway(name: headName),
              var queued = TestConfigFactory.throwaway(name: queuedName),
              let reimport = TestConfigFactory.throwaway(name: queuedName) else {
            fail("could not build the mint-race configs")
            return
        }
        head.createdAt = Date(timeIntervalSince1970: 1_000_000)
        queued.createdAt = Date(timeIntervalSince1970: 2_000_000)

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([head, queued]))
        faultVault.readAnswers = [
            head.id: .answersAfter(seconds: 2, .config(head)),
            queued.id: .answers(.config(queued)),
        ]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: FakeSlotFactory(canned: []),
            vault: faultVault,
            observesSystemChanges: false
        )

        let pass = Task { await manager.reconcileFromVault() }
        var waited = 0.0
        while !faultVault.readIds.contains(head.id), waited < 3 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        guard faultVault.readIds.contains(head.id) else {
            skip("environment: the pass never reached its first probe")
            _ = await pass.value
            return
        }
        guard !faultVault.readIds.contains(queued.id) else {
            skip("environment: the pass reached the queued candidate before its window could be driven")
            _ = await pass.value
            return
        }

        do {
            _ = try await manager.add(config: reimport)
        } catch {
            fail("the re-import failed outright: \(error.localizedDescription)")
            _ = await pass.value
            return
        }

        check(!faultVault.deletedIds.contains(queued.id),
              "a candidate still waiting its turn kept its payload through a same-name import — the mark covers the whole queue")
        let restored = await pass.value
        check(restored == 1,
              "and the pass restored the candidate it could — restored=\(restored), expected 1 (the other's name had been taken by the import)")
        check(!manager.tunnels.contains(where: { $0.id == queued.id }),
              "without minting a second row for the name the user had just imported")

        guard let holder = manager.tunnels.first(where: { $0.id == reimport.id }) else {
            fail("the re-imported row left the list before the mark could be checked")
            return
        }
        do {
            _ = try await manager.modify(tunnel: holder, with: reimport)
        } catch {
            fail("the edit that re-runs the dedup failed outright: \(error.localizedDescription)")
            return
        }
        check(faultVault.deletedIds.contains(queued.id),
              "and once the pass ends the mark is gone, so the same payload is dropped by the next write that reaches the dedup")
    }

    func reconcileReadsTheListAgainAfterProbing() async {
        let name = "TE-Mint-Relisted-\(runTag)"
        guard let candidate = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the relist config")
            return
        }
        let identity = TunnelIdentity(id: candidate.id, name: name, createdAt: candidate.createdAt, isGhost: false)
        let fake = FakeSlotProvider(name: "TE-Mint-Relisted-Projected-\(runTag)", identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([candidate]))
        faultVault.readAnswers = [candidate.id: .answersAfter(seconds: 2, .config(candidate))]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: FakeSlotFactory(canned: [fake]),
            vault: faultVault,
            observesSystemChanges: false
        )

        let pass = Task { await manager.reconcileFromVault() }
        var waited = 0.0
        while !faultVault.readIds.contains(candidate.id), waited < 3 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        guard faultVault.readIds.contains(candidate.id) else {
            skip("environment: the pass never reached its probe")
            _ = await pass.value
            return
        }

        guard !manager.tunnels.contains(where: { $0.id == candidate.id }) else {
            skip("environment: the pass minted before the reload could be driven")
            _ = await pass.value
            return
        }
        await manager.refresh()
        guard manager.tunnels.contains(where: { $0.id == candidate.id }) else {
            skip("environment: the reload did not list the row inside the probe window")
            _ = await pass.value
            return
        }

        let restored = await pass.value
        check(restored == 0,
              "the pass minted nothing for an id the list took while its payload was being proven — restored=\(restored)")
        check(manager.tunnels.filter { $0.id == candidate.id }.count == 1,
              "and the id is on the list exactly once — rows=\(manager.tunnels.filter { $0.id == candidate.id }.count)")
    }

    func reconcileGuardsTheNameItIsAboutToWrite() async {
        let takenName = "TE-Mint-Taken-\(runTag)"
        let freeName = "TE-Mint-Free-\(runTag)"
        guard var candidate = TestConfigFactory.throwaway(name: freeName),
              var follower = TestConfigFactory.throwaway(name: "TE-Mint-Follower-\(runTag)") else {
            fail("could not build the name-guard configs")
            return
        }
        candidate.createdAt = Date(timeIntervalSince1970: 1_000_000)
        follower.createdAt = Date(timeIntervalSince1970: 2_000_000)
        var renamedIntoCollision = candidate
        renamedIntoCollision.name = takenName

        let identity = TunnelIdentity(id: UUID(), name: takenName, createdAt: Date(), isGhost: false)
        let holder = FakeSlotProvider(name: takenName, identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([candidate, follower]))
        faultVault.readAnswers = [
            candidate.id: .answers(.config(renamedIntoCollision)),
            follower.id: .answers(.config(follower)),
        ]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [holder],
            providerFactory: FakeSlotFactory(canned: [holder]),
            vault: faultVault,
            observesSystemChanges: false
        )

        let restored = await manager.reconcileFromVault()

        check(!manager.tunnels.contains(where: { $0.id == candidate.id }),
              "the restore refused a payload whose CURRENT name is already on the list, so no second row carries that name")
        check(restored == 1,
              "and the candidate behind it was still restored — restored=\(restored), expected 1")
        check(faultVault.readIds.count == 2,
              "which is what says the refusal continued the pass rather than ending it — probes=\(faultVault.readIds.count), expected 2")
        check(manager.tunnels.count == 2, "leaving the holder and the sound restore — rows=\(manager.tunnels.count)")
    }

    func reconcileRefusesAPayloadItCannotTrust() async {
        guard var sound = TestConfigFactory.throwaway(name: "TE-Mint-Sound-\(runTag)"),
              var corrupt = TestConfigFactory.throwaway(name: "TE-Mint-Corrupt-\(runTag)"),
              var mismatched = TestConfigFactory.throwaway(name: "TE-Mint-Mismatched-\(runTag)") else {
            fail("could not build the refusal configs")
            return
        }
        var alien = mismatched
        alien.id = UUID()
        corrupt.createdAt = Date(timeIntervalSince1970: 1_000_000)
        mismatched.createdAt = Date(timeIntervalSince1970: 2_000_000)
        sound.createdAt = Date(timeIntervalSince1970: 3_000_000)

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([sound, corrupt, mismatched]))
        faultVault.readAnswers = [
            sound.id: .answers(.config(sound)),
            corrupt.id: .answers(.undecodable),
            mismatched.id: .answers(.config(alien)),
        ]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: FakeSlotFactory(canned: []),
            vault: faultVault,
            observesSystemChanges: false
        )

        let restored = await manager.reconcileFromVault()

        check(restored == 1, "only the sound payload became an entry — restored=\(restored), expected 1")
        check(manager.tunnels.contains(where: { $0.id == sound.id }), "and it is the one on the list")
        check(!manager.tunnels.contains(where: { $0.id == corrupt.id }),
              "a payload that no longer decodes was not minted from the snapshot the pass still held")
        check(!manager.tunnels.contains(where: { $0.id == mismatched.id })
                && !manager.tunnels.contains(where: { $0.id == alien.id }),
              "and a body whose id contradicts its key was minted under neither id")
        check(faultVault.readIds.count == 3,
              "neither refusal stopped the pass the way a dark vault does — probes=\(faultVault.readIds.count), expected 3")
    }

    func reconcileStopsMintingWhenTheVaultGoesDark() async {
        guard let first = TestConfigFactory.throwaway(name: "TE-Mint-Dark-1-\(runTag)"),
              let second = TestConfigFactory.throwaway(name: "TE-Mint-Dark-2-\(runTag)"),
              let third = TestConfigFactory.throwaway(name: "TE-Mint-Dark-3-\(runTag)") else {
            fail("could not build the dark-vault configs")
            return
        }

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([first, second, third]))
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: FakeSlotFactory(canned: []),
            vault: faultVault,
            observesSystemChanges: false
        )

        let restored = await manager.reconcileFromVault()

        check(restored == 0, "nothing was minted from payloads the vault would not confirm — restored=\(restored)")
        check(manager.tunnels.isEmpty, "and the list stayed empty — tunnels=\(manager.tunnels.count)")
        check(faultVault.readIds.count == 1,
              "the first silence stopped the pass — probes=\(faultVault.readIds.count), expected 1 for 3 candidates")
    }

    func aRestorePutsTheTunnelBackAsAnEntry() async {
        guard let lost = TestConfigFactory.throwaway(name: "TE-Restore-Whole-\(runTag)") else {
            fail("the config factory did not produce the throwaway this step needs")
            return
        }

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([lost]))
        faultVault.readAnswers = [lost.id: .answers(.config(lost))]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        let factory = FakeSlotFactory(canned: [])
        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: factory,
            vault: faultVault,
            observesSystemChanges: false
        )

        let restored = await manager.reconcileFromVault()

        check(restored == 1, "the pass restored the tunnel the system had lost — restored=\(restored), expected 1")
        check(manager.tunnels.filter { $0.id == lost.id }.count == 1,
              "listed exactly once — rows=\(manager.tunnels.filter { $0.id == lost.id }.count)")
        guard let row = manager.tunnels.first(where: { $0.id == lost.id }) else {
            fail("the pass reported a restore that put no row on the list")
            return
        }
        check(row.name == lost.name, "under the payload's own name — '\(row.name)'")

        guard factory.minted.providers.count == 1, let minted = factory.minted.last else {
            fail("the pass minted \(factory.minted.providers.count) provider(s) for one candidate — "
                 + "the entry checks below would not know which to read")
            return
        }
        check(minted.entryExists,
              "and the system really holds that configuration: the save landed, rather than the row being "
              + "appended around an object nothing accepted")
        check(minted.tunnelIdentity?.id == lost.id && minted.tunnelIdentity?.name == lost.name,
              "carrying the payload's own identity — id and name both, which is what the next reload will match it by")
        check(minted.isEnabled,
              "with the manager enabled before that save, so the tunnel the user gets back is one that can start — read on "
              + "the process's copy, since the fake models the store for the projection but not for this flag")
        check(row.tunnelProvider === minted,
              "and the row the user sees wraps that entry rather than a stand-in beside it — with no reload armed in this "
              + "rig, the pass's own append is the only way the row could have arrived")
    }

    // Realign reaches a row whose reading went unknown: a drifted
    // projection over a live `.invalid` is exactly the kind of row a save
    // can repair, while a row with a live session is never written under it.
    func realignReachesARowGoneUnknown() async {
        let unknownName = "TE-Realign-Unknown-\(runTag)"
        let liveName = "TE-Realign-Live-\(runTag)"
        guard let unknownConfig = TestConfigFactory.throwaway(name: unknownName),
              let liveConfig = TestConfigFactory.throwaway(name: liveName) else {
            fail("could not build the realign configs")
            return
        }
        let staleUnknown = TunnelIdentity(id: unknownConfig.id, name: unknownName + "-stale",
                                          createdAt: unknownConfig.createdAt, isGhost: false)
        let staleLive = TunnelIdentity(id: liveConfig.id, name: liveName + "-stale",
                                       createdAt: liveConfig.createdAt, isGhost: false)
        let fakeUnknown = FakeSlotProvider(name: staleUnknown.name, identity: staleUnknown, status: .invalid)
        let fakeLive = FakeSlotProvider(name: staleLive.name, identity: staleLive, status: .connected)

        let faultVault = FaultVaultClient()
        faultVault.readAnswer = .answers(.unreachable)
        // The realign proves every candidate fresh before writing (the mint
        // path's discipline); a rig that answers only readAll would read as a
        // dark vault and stop the pass before any write.
        faultVault.readAnswers = [
            unknownConfig.id: .answers(.config(unknownConfig)),
            liveConfig.id: .answers(.config(liveConfig)),
        ]
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)
        faultVault.readAllAnswer = .answers(.configs([unknownConfig, liveConfig]))

        let manager = TunnelsManager(
            tunnelProviders: [fakeUnknown, fakeLive],
            providerFactory: FakeSlotFactory(canned: [fakeUnknown, fakeLive]),
            vault: faultVault,
            observesSystemChanges: false
        )
        guard let row = manager.tunnels.first(where: { $0.id == unknownConfig.id }) else {
            fail("side manager did not materialize the unknown drifted row")
            return
        }
        guard check(row.status == .unknown,
                    "the drifted row starts on a dead reading — painted unknown") else { return }

        await manager.refresh()

        check(fakeUnknown.saveCount == 1,
              "reconcile realigned the unknown row — the drifted projection took the vault's write "
              + "(saves=\(fakeUnknown.saveCount), expected 1)")
        check(fakeUnknown.tunnelIdentity?.name == unknownName && row.name == unknownName,
              "and the projection and the row both carry the vault's name again — "
              + "projection=\(fakeUnknown.tunnelIdentity?.name ?? "nil")")
        check(fakeLive.saveCount == 0,
              "while the row with a live session was not written under it (saves=\(fakeLive.saveCount), expected 0)")
        check(fakeLive.tunnelIdentity?.name == staleLive.name,
              "so its projection still shows the drift a later grounded pass will repair — "
              + "name=\(fakeLive.tunnelIdentity?.name ?? "nil")")
    }
}
#endif
