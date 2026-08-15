#if DEBUG
import Foundation
import NetworkExtension

// MARK: - Custody reads — what the app believes about a payload at the
// moment it acts on it, as opposed to what a bulk answer said earlier.
//
// These steps run over a `FaultVaultClient` and side managers rather
// than the user's own list: every claim here needs a vault whose
// answers can be made to disagree — with themselves between the bulk
// answer and the per-id one, with the list the app is holding, or with
// the clock, by staying out long enough for a second caller to arrive.
// The real vault cannot be asked to do any of that on purpose. Nothing
// they drive reaches it or the system's preferences, so they plant
// nothing and need no teardown net — the one shape of harness residue
// this file is free of.
//
// "Free of" rather than "free of by construction", because the fault
// client's default is to FORWARD: a surface left `.real` reaches the
// user's own vault. Every step here therefore sets every surface,
// including ones its own path should never touch, so a call the step
// did not anticipate answers a fabrication instead of a keychain.
extension VaultIntegrityWorkflow {

    /// The purge that keeps names unique must not take a LIVE tunnel's
    /// secret with it.
    ///
    /// The two name guards read different stores — the list's names
    /// before the write, the vault's names inside the purge — and
    /// `modify` parts them on its own: it writes the new name to the
    /// vault first, and a refused preference save rolls the projection
    /// back, leaving a listed tunnel whose payload already carries a
    /// name the list does not show. Reusing that name then walks past
    /// the list guard, and the purge finds a payload that looks exactly
    /// like an orphan. Deleting it is not a stale-entry cleanup, it is
    /// the live tunnel's only copy of its key.
    ///
    /// Three halves, because the bar has two readings and one licence:
    /// a payload on the list is spared, a payload that really is an
    /// orphan is still dropped, and a payload whose entry is being
    /// created right now is spared too. Without the second the step
    /// would pass against a fix that simply stopped purging; without
    /// the third it would pass against a bar that reads only the list,
    /// which is what the first version of this fix was.
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
        // The drift: one id, listed under the OLD name, stored under
        // the new one.
        drifted.id = listedId

        let identity = TunnelIdentity(id: listedId, name: listedName, createdAt: Date(), isGhost: false)
        let fake = FakeSlotProvider(name: listedName, identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([drifted]))
        // Every surface the import will touch is fabricated. Left
        // `.real`, the store below would write a throwaway into the
        // user's own vault and the delete would reach for a payload
        // there.
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)
        // Nothing on this path reads a single payload; fabricated all
        // the same, so a call the step did not anticipate cannot reach
        // the user's own vault.
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

        // Second half: an orphan is still an orphan. Same purge, same
        // name collision, but this payload's id is on no list.
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

    /// Third half of the purge claim, in its own body because the step
    /// carries three arrangements and the ruler measures them together.
    ///
    /// The window between a payload landing and its entry landing:
    /// `add` marks the id in `creatingIds` and then suspends for
    /// seconds inside the vault write and two NE round-trips, with the
    /// main actor free for all of it — so a second import during that
    /// window reads a list that does not hold the first tunnel yet, and
    /// a bar that only reads the list would take its secret.
    private func purgeSparesAPayloadBeingCreated(
        on manager: TunnelsManager,
        vault faultVault: FaultVaultClient,
        racer: TunnelConfig,
        rival: TunnelConfig
    ) async {
        faultVault.readAllAnswer = .answers(.configs([]))
        faultVault.storeAnswer = .answersAfter(seconds: 2, .done)
        let racing = Task { () -> Bool in
            do {
                _ = try await manager.add(config: racer)
                return true
            } catch {
                return false
            }
        }
        // The ledger is the signal: an id appears there BEFORE its
        // answer is waited out, so seeing it means `add` is past its
        // own mark and inside the write.
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
        // And the window has to still be open. If the first import has
        // already landed its entry, the row is on the list and the bar
        // would spare that payload for the OTHER reading — the step
        // would print green having measured the wrong clause. That is
        // the machine being slow, not a promise broken.
        guard !manager.tunnels.contains(where: { $0.id == racer.id }) else {
            skip("environment: the first import landed before its creation window could be driven")
            _ = await racing.value
            return
        }
        faultVault.storeAnswer = .answers(.done)
        faultVault.readAllAnswer = .answers(.configs([racer]))
        do {
            _ = try await manager.add(config: rival)
        } catch {
            fail("the racing import failed outright: \(error.localizedDescription)")
            _ = await racing.value
            return
        }
        check(!faultVault.deletedIds.contains(racer.id),
              "and a payload whose entry is still being created keeps its secret through a second import of the same name")
        // Asserted AFTER the claim above, and it guards the claim
        // rather than repeating it: a failed create rolls its own
        // payload back, and that rollback would put this id in the
        // delete ledger for a reason that has nothing to do with the
        // purge. The check above is read before the first import
        // resumes, so it cannot see that rollback — this is what says
        // there was none to see.
        let racerLanded = await racing.value
        check(racerLanded, "with the first import landing on its own terms, so no rollback of its own touched that payload")
        // Both imports land, and the list ends up holding two tunnels
        // with one name. That is the list guard's own window, not this
        // claim: the payload was the thing that could not be recovered.
    }

    /// Reconcile must prove a payload is still there at the moment it
    /// mints an entry for it, not when the pass began — and must mint
    /// what the payload says NOW.
    ///
    /// `readAll` answers, then every candidate before this one suspends
    /// again minting its own entry, and removals run through all of it.
    /// A payload deleted inside that window still sits in the snapshot,
    /// and minting from it hands the world an entry whose secret is
    /// gone: invisible to the list (the ownership boundary reads an
    /// unbacked entry as another user's), undeletable for the same
    /// reason, and self-reconnecting if it was minted armed.
    ///
    /// Two candidates with opposite verdicts, so the step proves the
    /// probe is PER ID rather than one gate the whole pass shares — a
    /// pass that asked once and applied the answer to both would pass a
    /// single-candidate version of this step. And the surviving
    /// candidate's fresh payload deliberately DISAGREES with the
    /// snapshot, which is the only way to see which of the two the
    /// entry was born from — and to catch the realign half of the same
    /// pass writing the snapshot back over it.
    func reconcileProvesAPayloadBeforeMinting() async {
        guard var present = TestConfigFactory.throwaway(name: "TE-Mint-Present-\(runTag)"),
              var vanished = TestConfigFactory.throwaway(name: "TE-Mint-Vanished-\(runTag)") else {
            fail("could not build the reconcile configs")
            return
        }
        var renamed = present
        renamed.name = "TE-Mint-Renamed-\(runTag)"
        // Candidates are worked oldest first, and the ORDER is what
        // makes the probe count discriminating: the refusal goes first
        // and the mint last, so a refusal that wrongly stopped the pass
        // the way a dark answer does would leave the second candidate
        // unprobed and unminted, and both counts below would fall.
        vanished.createdAt = Date(timeIntervalSince1970: 1_000_000)
        present.createdAt = Date(timeIntervalSince1970: 2_000_000)
        renamed.createdAt = present.createdAt

        let faultVault = FaultVaultClient()
        // The stale bulk answer carries both, under the OLD name.
        faultVault.readAllAnswer = .answers(.configs([present, vanished]))
        // The truth at mint time: one is there under a NEW name, one
        // was deleted while the pass ran.
        faultVault.readAnswers = [
            present.id: .answers(.config(renamed)),
            vanished.id: .answers(.missing),
        ]
        // Every surface fabricated, including the ones this pass should
        // never reach: a `.real` surface here would be a silent path to
        // the user's own vault the moment the code under test grew a
        // call the step did not anticipate.
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

    /// A reconcile pass marks its candidates in flight before it probes
    /// any of them, not as each one's turn comes.
    ///
    /// One leg is deliberately not driven here because the production
    /// code does not claim it: the pass's own bulk read runs before
    /// candidacy exists, so nothing can be marked across it. What is
    /// claimed, and what this drives, is that the mark leads the probes
    /// and covers the queue behind the one in hand.
    ///
    /// The asymmetry with `add` is the whole point: an add marks an id
    /// whose payload does not exist yet, while a restore's candidate
    /// has had a payload in the vault since the bulk answer — with no
    /// list row beside it, which is exactly what the duplicate purge
    /// reads as an orphan. So every await the pass takes before its
    /// entry lands is a window in which a same-name import can delete
    /// the payload the pass is about to mint from, and the entry would
    /// be born with its secret already gone. The probe's own round-trip
    /// is the first of those awaits, and the version of this fix that
    /// marked afterwards left it wide open.
    ///
    /// The candidate driven here is the QUEUED one, not the one being
    /// probed, because the queue is where the window is widest: a pass
    /// that marked each candidate as its turn came would leave every
    /// candidate behind it unlisted and unmarked for the length of the
    /// queue ahead — one probe and two NE round-trips each — which is
    /// exactly the extension-reinstall case, many entries missing at
    /// once and a user re-importing from a short list.
    func reconcileMarksItsCandidateBeforeItAsks() async {
        let headName = "TE-Mint-Race-Head-\(runTag)"
        let queuedName = "TE-Mint-Race-Queued-\(runTag)"
        guard var head = TestConfigFactory.throwaway(name: headName),
              var queued = TestConfigFactory.throwaway(name: queuedName),
              let reimport = TestConfigFactory.throwaway(name: queuedName) else {
            fail("could not build the mint-race configs")
            return
        }
        // Candidates are worked oldest first, so these dates are what
        // put `queued` behind `head` in the queue.
        head.createdAt = Date(timeIntervalSince1970: 1_000_000)
        queued.createdAt = Date(timeIntervalSince1970: 2_000_000)

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([head, queued]))
        faultVault.readAnswers = [
            // Held open on purpose: while the pass waits here, `queued`
            // is a payload with no list row and the whole window this
            // step is about.
            head.id: .answersAfter(seconds: 2, .config(head)),
            queued.id: .answers(.config(queued)),
        ]
        // Anything else asking would be a probe this step did not
        // arrange, and a dark answer makes that visible instead of
        // letting it pass for arrangement.
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

        // The user, who cannot see either tunnel in the list, re-imports
        // the queued one's configuration. A fresh id, as every import
        // carries, so the purge treats the old payload as another
        // record entirely.
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

        // And the mark comes DOWN when the pass ends. Without this the
        // step would pass just as happily against a mark that is never
        // lowered — which would quietly make every candidate id
        // unpurgeable for the life of the process. The same name is
        // written again, this time with no pass in flight: an edit
        // reaches the deduplication because its name guard excludes the
        // tunnel's own id, and the orphan must now be dropped.
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

    /// The list is read again after the probe, because the probe is a
    /// suspension and the reading that admitted this candidate is that
    /// much older.
    ///
    /// Before the probe existed, the "no second entry for one id" test
    /// and the mint were adjacent and one reading served both. A reload
    /// landing in the probe's window can list the very id being proven
    /// — an entry the ownership boundary held back in an earlier dark
    /// window is the shape that does it — and minting on the older
    /// reading would create exactly the second entry the loop forbids.
    func reconcileReadsTheListAgainAfterProbing() async {
        let name = "TE-Mint-Relisted-\(runTag)"
        guard let candidate = TestConfigFactory.throwaway(name: name) else {
            fail("could not build the relist config")
            return
        }
        // The provider the system will hand back mid-pass: same id, so
        // ingest lists exactly the row this pass is about to mint.
        //
        // Its PROJECTED name deliberately differs from the payload's.
        // The two list tests run in one helper and the name test is one
        // of them, so a row projecting the same name would refuse this
        // mint on the name and the id test would never be reached — the
        // step would print green with the line it exists for deleted.
        // Diverging the projection leaves the id test as the only
        // possible refusal. The identity keeps the payload's name so
        // the realign half still sees no drift and stays out of it.
        let identity = TunnelIdentity(id: candidate.id, name: name, createdAt: candidate.createdAt, isGhost: false)
        let fake = FakeSlotProvider(name: "TE-Mint-Relisted-Projected-\(runTag)", identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
        faultVault.readAllAnswer = .answers(.configs([candidate]))
        faultVault.readAnswers = [candidate.id: .answersAfter(seconds: 2, .config(candidate))]
        faultVault.readAnswer = .answers(.unreachable)
        faultVault.storeAnswer = .answers(.done)
        faultVault.deleteAnswer = .answers(.done)

        // The list starts EMPTY while the factory already holds the
        // provider: that is the system knowing something the list does
        // not, which is what the reload in the window then corrects.
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

        // The window has to still be open. Before the reload, the only
        // writer that can put this id on the list is the pass's own
        // mint, so finding it there means the probe already answered
        // and there is nothing left to drive.
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

    /// The name a restore guards is the one it is about to WRITE, which
    /// is the freshly read payload's, not the snapshot's.
    ///
    /// The guard exists so the restore is never the path that
    /// manufactures a duplicate name. Reading the stale name would test
    /// a name nobody is about to write: a payload renamed since the
    /// bulk answer would slip past a free-looking snapshot name and
    /// land a second row carrying a name the list already shows.
    ///
    /// A second candidate follows the refused one, and it is what makes
    /// the refusal's SHAPE measurable. This is the loop's third refusal
    /// site and the only one that judges the LIST rather than the
    /// payload, but it owes the pass what the probe's own refusals owe
    /// it: only a vault that did not answer may stop the minting. A
    /// guard that stopped here instead of continuing would abandon
    /// every candidate behind a name collision — a genuinely lost
    /// tunnel left missing until some later trigger, with nothing in
    /// the log to say why.
    func reconcileGuardsTheNameItIsAboutToWrite() async {
        let takenName = "TE-Mint-Taken-\(runTag)"
        let freeName = "TE-Mint-Free-\(runTag)"
        guard var candidate = TestConfigFactory.throwaway(name: freeName),
              var follower = TestConfigFactory.throwaway(name: "TE-Mint-Follower-\(runTag)") else {
            fail("could not build the name-guard configs")
            return
        }
        // The refused candidate is worked FIRST, the sound one after it.
        candidate.createdAt = Date(timeIntervalSince1970: 1_000_000)
        follower.createdAt = Date(timeIntervalSince1970: 2_000_000)
        var renamedIntoCollision = candidate
        renamedIntoCollision.name = takenName

        let identity = TunnelIdentity(id: UUID(), name: takenName, createdAt: Date(), isGhost: false)
        let holder = FakeSlotProvider(name: takenName, identity: identity, status: .disconnected)

        let faultVault = FaultVaultClient()
        // The snapshot's name is free; the payload's name, as it reads
        // now, is the one the listed row already holds.
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

    /// The two refusals a restore makes about the payload ITSELF, as
    /// opposed to about the list: a body that no longer decodes, and a
    /// body whose own id contradicts the key it was read under.
    ///
    /// Neither is a vault that failed to answer, so neither may stop
    /// the pass — that is what separates them from the dark verdict,
    /// and it is why the probe count is asserted alongside the
    /// restores: three candidates, three probes, one entry.
    func reconcileRefusesAPayloadItCannotTrust() async {
        guard var sound = TestConfigFactory.throwaway(name: "TE-Mint-Sound-\(runTag)"),
              var corrupt = TestConfigFactory.throwaway(name: "TE-Mint-Corrupt-\(runTag)"),
              var mismatched = TestConfigFactory.throwaway(name: "TE-Mint-Mismatched-\(runTag)") else {
            fail("could not build the refusal configs")
            return
        }
        // The body the vault answers with under `mismatched`'s key
        // carries somebody else's id — a custody anomaly the app's own
        // writes cannot produce, since the key IS the id it encodes.
        var alien = mismatched
        alien.id = UUID()
        // Both refusals sort BEFORE the sound payload, which is what
        // makes the counts below discriminating: a refusal that stopped
        // the pass the way a dark answer does would leave the sound one
        // unprobed and unminted.
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

    /// A vault that goes dark partway stops the minting where it went
    /// dark, rather than paying a timeout per candidate.
    ///
    /// The same conservatism `ingest` applies to an unproven entry, and
    /// for the sharper reason here: a candidate whose payload cannot be
    /// proven present is exactly the one this pass must not mint from.
    /// The count IS the claim — a pass that probed all three and minted
    /// none would look identical from the outside.
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
}
#endif
