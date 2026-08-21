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
// Tunnel Edit
//
// The EDIT path: what `modify()` refuses, and what it leaves behind when
// it gets half-way.
//
// This is the user's third action on a tunnel, after creating one and
// removing one, and until this file existed no step took it as its
// subject — `modify` was reached exactly once in the whole engine, as the
// ARRANGE half of a purge claim, which measures the deduplication it
// triggers rather than the edit itself.
//
// Everything here runs over fabricated stores: a listed row whose provider
// is handed BOTH as the manager's opening row and as the factory's canned
// answer, so it stays the same object on every path — a reload that
// rebuilds the list from the system finds this provider rather than a
// fresh stand-in, and the counters a step reads are the ones the code
// actually wrote. Nothing reaches the user's list or the real vault.
//
// The starting vault answers, and answers about NOTHING: `readAll` returns
// an empty list on purpose, because `modify` runs deduplication before it
// writes and a payload answering there would hand the purge a candidate —
// a delete these claims are not about, arriving in the middle of the
// window they are about.
//
// Scenarios:
//
//   A — An Edit The Vault Refuses Never Reaches The System
//       The vault says no and the refusal is carried as a REFUSAL; then
//       the same edit against a SILENT vault, which must reach the user as
//       the other sentence.
//   B — A Failed Save Puts The Projection Back
//   C — A Rollback The System Refuses Leaves The Projection Agreeing With
//       The Vault
//       Named for the pair that AGREES rather than for "both stores": in
//       this engine's vocabulary those are the vault and the system's
//       preference store, and this step's whole point is that those two
//       part company. What ends up agreeing is the vault and the
//       in-process projection.
//   D — An Edit Is Refused While The Row Is Being Removed
//   E — A Name Another Row Holds Is Refused, Its Own Is Not
//   F — A Blank Name Is Refused Before Either Store Is Touched

#if DEBUG
import Foundation
import NetworkExtension

/// The EDIT path: what `modify()` refuses, and what it leaves behind
/// when it gets half-way.
///
/// This is the user's third action on a tunnel — after creating one and
/// removing one — and until this file existed no step took it as its
/// subject. `modify` was reached exactly once in the whole engine, as
/// the ARRANGE half of a purge claim, which measures the deduplication
/// it triggers rather than the edit itself.
///
/// It matters more than a third action usually would, and the reason
/// has to be stated precisely, because all three CRUD paths write both
/// stores in one call: `add` creates a payload and an entry, `remove`
/// empties both. What is unique here is that both of this path's writes
/// are UPDATES to a row that goes on existing either way. An
/// interrupted `add` leaves an orphan payload and an interrupted
/// `remove` leaves a residue — shapes with their own repair passes and
/// their own witnesses. An interrupted EDIT leaves a pair that both
/// stores still hold, listed, startable, with only their contents
/// disagreeing — and nothing DROPS a row for that. The repair is
/// in-place and it is the realign, which is why this path's rollback
/// decides whether the repair can still see anything to do, where the
/// other two are repaired by passes that add or remove.
///
/// The vault takes the edit first and the system takes it second, so a
/// save that fails leaves the payload holding a name the system never
/// accepted — and the app's own account of that state is the
/// projection, which the failure arm puts back by re-reading. Whether
/// that rollback runs decides whether the drift stays in the realign's
/// reach at all: the reconcile realign detects a stale
/// projection by comparing the vault payload against exactly that
/// value, so a projection left agreeing with the vault makes the
/// mismatch undetectable while the system still shows the old name.
///
/// Every surface here is fabricated — a `FaultVaultClient` for the
/// payload store and canned `FakeSlotProvider`s behind a
/// `FakeSlotFactory` for the system's — so no step touches the user's
/// vault or NE preferences, plants no payload and no entry, and leaves
/// no session. There is no teardown net in this file because there is
/// nothing for one to sweep, said here so that its absence reads as a
/// fact rather than an omission.
///
/// Each side manager is built with `observesSystemChanges: false`, and
/// the reason here is not the one the seam's rigs carry. Those hand
/// their manager the REAL vault, so a stray reload asks the ownership
/// boundary about ids it has never heard of and drops the rows. These
/// rigs hand it a fabricated vault that answers for their ids, so the
/// rows would survive that question. What a reload would do instead is
/// rebuild the list from the fake factory's own view of which entries
/// exist — evicting the row the removal step is measuring at the exact
/// moment its entry is taken — and run a reconcile inside the window
/// under test. The flag keeps the window the step's own.
final class TunnelEditWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Edit (Refusals + The Projection Rollback)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("An Edit The Vault Refuses Never Reaches The System",
                         aRefusedEditNeverReachesTheSystem),
            WorkflowStep("A Failed Save Puts The Projection Back",
                         aFailedSavePutsTheProjectionBack),
            // Named for the pair that AGREES, not for "both stores":
            // in this engine's vocabulary those are the vault and the
            // system's preference store, and this step's whole point is
            // that those two part company. What ends up agreeing is the
            // vault and the in-process projection.
            WorkflowStep("A Rollback The System Refuses Leaves The Projection Agreeing With The Vault",
                         aRefusedRollbackLeavesTheProjectionAgreeingWithTheVault),
            WorkflowStep("An Edit Is Refused While The Row Is Being Removed",
                         anEditIsRefusedDuringARemoval),
            WorkflowStep("A Name Another Row Holds Is Refused, Its Own Is Not",
                         aTakenNameIsRefusedAndItsOwnIsNot),
            WorkflowStep("A Blank Name Is Refused Before Either Store Is Touched",
                         aBlankNameIsRefusedBeforeAnyWrite),
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))

    // MARK: - Rig

    /// A listed row over fabricated stores, with the provider handed
    /// back so a step can drive and read the system's side.
    ///
    /// The provider is passed BOTH as the manager's opening row and as
    /// the factory's canned answer, which is what makes it the same
    /// object on every path: a reload that rebuilds the list from the
    /// system finds this provider rather than a fresh stand-in, so the
    /// counters and the projection a step reads are the ones the code
    /// under test wrote.
    private func rig(
        name: String,
        vault: FaultVaultClient
    ) -> (manager: TunnelsManager, provider: FakeSlotProvider, config: TunnelConfig)? {
        guard let config = TestConfigFactory.throwaway(name: name) else { return nil }
        let provider = FakeSlotProvider(
            name: config.name,
            identity: config.identity,
            status: .disconnected
        )
        let manager = TunnelsManager(
            tunnelProviders: [provider],
            providerFactory: FakeSlotFactory(canned: [provider]),
            vault: vault,
            observesSystemChanges: false
        )
        return (manager, provider, config)
    }

    /// The vault every step starts from: answering, and answering
    /// about nothing.
    ///
    /// `readAll` returns an empty list on purpose. `modify` runs the
    /// deduplication before it writes, and a payload answering there
    /// would give the purge a candidate — a delete this file's claims
    /// are not about, arriving in the middle of the window they are
    /// about. The per-id read is fabricated too, so a probe no step
    /// arranged cannot fall through to the user's own vault.
    private func answeringVault() -> FaultVaultClient {
        let vault = FaultVaultClient()
        vault.readAllAnswer = .answers(.configs([]))
        vault.readAnswer = .answers(.unreachable)
        vault.storeAnswer = .answers(.done)
        vault.deleteAnswer = .answers(.done)
        return vault
    }

    private func edited(_ config: TunnelConfig, to name: String) -> TunnelConfig {
        var next = config
        next.name = name
        return next
    }

    // MARK: - Steps

    /// The vault answers no, and the refusal is carried as a REFUSAL —
    /// then the same edit against a silent vault, which must reach the
    /// user as the other sentence.
    ///
    /// Two halves, each the other's control. The first alone would pass
    /// against code that collapsed both answers into one error, since
    /// it never asks what silence produces; the second alone would pass
    /// against code that called everything a refusal. Together they
    /// pin the distinction the typed verdict was introduced for, on the
    /// third CRUD path. Production carries that verdict on all three —
    /// `remove` runs its writes through the same helper — but the step
    /// that PINS it existed only for `add`.
    ///
    /// The system's side is read as well, and that is the sharper
    /// claim: a refused payload write must not leave the identity
    /// projection moved. The order in production is what earns it — the
    /// vault is asked before the provider is touched — so a `saveCount`
    /// of zero here is not an accident of timing but the contract.
    private func aRefusedEditNeverReachesTheSystem() async {
        let vault = answeringVault()
        guard let rig = rig(name: "TE-Edit-Refused-\(runTag)", vault: vault) else {
            fail("the config factory did not produce the throwaway this step needs")
            return
        }
        guard let row = rig.manager.tunnels.first(where: { $0.id == rig.config.id }) else {
            fail("the side manager did not materialize the listed tunnel")
            return
        }
        let originalName = rig.config.name
        let rename = edited(rig.config, to: "TE-Edit-Refused-New-\(runTag)")

        vault.storeAnswer = .answers(.refused)
        do {
            try await rig.manager.modify(tunnel: row, with: rename)
            fail("the edit reported success over a vault that refused the write")
            return
        } catch {
            guard case TunnelManagementError.vaultRefused = error else {
                fail("a refused vault write surfaced as \(error) rather than the refusal case")
                return
            }
        }

        check(rig.provider.saveCount == 0,
              "and the system was never asked: the refusal stopped the edit before the provider was touched — saves=\(rig.provider.saveCount), expected 0")
        check(rig.provider.localizedDescription == originalName,
              "so the identity projection still carries the name the system holds")
        check(row.name == originalName,
              "and the row the user is looking at keeps its name")

        // Silence, same edit, same rig. The vault is the only thing
        // that changes.
        vault.storeAnswer = .answers(.unreachable)
        do {
            try await rig.manager.modify(tunnel: row, with: rename)
            fail("the edit reported success over a vault that never answered")
            return
        } catch {
            guard case TunnelManagementError.vaultUnavailable = error else {
                fail("a silent vault surfaced as \(error) rather than the unavailable case")
                return
            }
        }
        check(rig.provider.saveCount == 0,
              "and silence stopped it in the same place, told apart from the refusal in the copy the user reads")
    }

    /// The payload write lands, the system's save fails, and the arm
    /// that runs next re-reads the preferences to put the projection
    /// back.
    ///
    /// This is the app's own producer of the drift the campaign named:
    /// the vault ends up holding the edit while the system holds the
    /// old configuration. What this step measures is the ONE thing that
    /// keeps that state repairable — the projection going back to what
    /// the store actually holds, so the realign's comparison can still
    /// see a mismatch.
    ///
    /// The re-read is proven by `loadCount` rather than inferred from
    /// the value it would have produced: the value alone cannot tell a
    /// rollback that ran from a save that never moved the projection in
    /// the first place, and the rollback is exactly the line whose
    /// deletion this step must turn red.
    private func aFailedSavePutsTheProjectionBack() async {
        let vault = answeringVault()
        guard let rig = rig(name: "TE-Edit-Rollback-\(runTag)", vault: vault) else {
            fail("the config factory did not produce the throwaway this step needs")
            return
        }
        guard let row = rig.manager.tunnels.first(where: { $0.id == rig.config.id }) else {
            fail("the side manager did not materialize the listed tunnel")
            return
        }
        let originalName = rig.config.name
        let newName = "TE-Edit-Rollback-New-\(runTag)"
        let rename = edited(rig.config, to: newName)

        let loadsBefore = rig.provider.loadCount
        rig.provider.saveAnswer = .fails(NSError(
            domain: "TE.Edit", code: 61,
            userInfo: [NSLocalizedDescriptionKey: "the system refused the edit's save"]))

        do {
            try await rig.manager.modify(tunnel: row, with: rename)
            fail("the edit reported success over a save the system refused")
            return
        } catch {
            guard case TunnelManagementError.vpnSystemErrorOnModifyTunnel = error else {
                fail("a refused save surfaced as \(error) rather than the modify case")
                return
            }
        }

        check(rig.provider.loadCount == loadsBefore + 1,
              "the rollback re-read RAN — loads=\(rig.provider.loadCount), expected \(loadsBefore + 1)")
        check(rig.provider.localizedDescription == originalName,
              "and it put the projection back to what the system actually holds, not the name this process wrote")
        // The identity is read here for completeness, and what it can
        // establish is narrower than the line above it: the provider was
        // BORN with this identity, so this reading is the same whether
        // the rollback put it back or `modify()` never moved it. The
        // reading that can tell those apart lives in the step below,
        // where nothing repaints — this one only says the rollback did
        // not leave the two projection fields disagreeing with each
        // other.
        check(rig.provider.tunnelIdentity?.name == originalName,
              "identity included, so the rollback left no half-repainted projection behind — though only the refused-rollback "
              + "step can tell this apart from an identity that was never moved")
        check(row.name == originalName,
              "the row keeps its old name, since the line that renames it is past the throw")

        // The other half of the state, and the reason the rollback is
        // load-bearing rather than tidy: the payload store DID take the
        // edit, so the two stores now disagree and something has to be
        // able to tell.
        check(vault.storedConfigs.last(where: { $0.id == rig.config.id })?.name == newName,
              "while the vault holds the EDIT itself — the drift is real, and the projection above is what leaves it detectable")
    }

    /// The same failure, with the re-read refused as well.
    ///
    /// Production takes this arm with `try?` and its comment says what
    /// it costs. This step holds that sentence to a measurement, because
    /// the cost is not merely "the projection is stale" — it is that the
    /// projection now AGREES with the vault while the system holds
    /// neither, and agreement is what the realign reads as "nothing to
    /// do". The drift stops being pending and becomes undetectable.
    ///
    /// UNDETECTABLE UNTIL SOMETHING ELSE READS OR WRITES THIS
    /// PROVIDER'S PREFERENCES, and the step does not claim more than
    /// that. The drifted values live on the provider OBJECT, which
    /// outlives every reload — an ingest keeps the existing container
    /// and copies the name into it rather than replacing it — so the
    /// state ends whenever anything touches that object's preferences
    /// again: an activation's arm save serializes the whole projection
    /// and carries the pending rename into the store, a refused
    /// disarm's re-read puts the store's copy back and re-arms the
    /// drift test, another edit repairs it outright, and failing all of
    /// those the next launch rebuilds the row from the store.
    ///
    /// The ordering of those is deliberately NOT claimed. This sentence
    /// has now been wrong twice in this package — first as "the drift
    /// is permanent", then as "it survives this process" — and both
    /// times because it predicted a repair timeline that depends on
    /// three subsystems this step drives none of. What the step
    /// measures is the local fact: at the moment `modify()` returns,
    /// the value the realign compares equals the vault's, so that test
    /// has nothing to fire on.
    ///
    /// Nothing here is a product defect to fix in this package: the
    /// alternative to `try?` is throwing away the more accurate error
    /// the caller is already carrying.
    ///
    /// The step reads the IDENTITY as well as the description, and that
    /// is not thoroughness. The realign's drift test reads
    /// `tunnelIdentity` (the drift test at the top of
    /// `realignDriftedProjections`'s loop), which `modify()`
    /// writes on its own line — so without that reading, this step's
    /// own closing sentence would be a claim about a field it never
    /// looked at. It is ONE of two guards on that write: this one
    /// catches it through the process's copy under a REFUSED save, and
    /// the naming step's `storedIdentity` reading catches it through
    /// the store under a save that LANDS. Neither is redundant —
    /// deleting `configure(with:)` turns both red, but only this one
    /// covers the arm where nothing repaints. The two
    /// counters carry the rest: `loadCount` is what says the refused
    /// re-read was ISSUED rather than absent, and `saveCount` is what
    /// says the store's silence is a refusal this step drove rather
    /// than a write nobody attempted.
    private func aRefusedRollbackLeavesTheProjectionAgreeingWithTheVault() async {
        let vault = answeringVault()
        guard let rig = rig(name: "TE-Edit-DarkRollback-\(runTag)", vault: vault) else {
            fail("the config factory did not produce the throwaway this step needs")
            return
        }
        guard let row = rig.manager.tunnels.first(where: { $0.id == rig.config.id }) else {
            fail("the side manager did not materialize the listed tunnel")
            return
        }
        let originalName = rig.config.name
        let newName = "TE-Edit-DarkRollback-New-\(runTag)"
        let rename = edited(rig.config, to: newName)

        rig.provider.saveAnswer = .fails(NSError(
            domain: "TE.Edit", code: 62,
            userInfo: [NSLocalizedDescriptionKey: "the system refused the edit's save"]))
        rig.provider.loadAnswer = .fails(NSError(
            domain: "TE.Edit", code: 63,
            userInfo: [NSLocalizedDescriptionKey: "the system refused the re-read too"]))
        let loadsBefore = rig.provider.loadCount

        do {
            try await rig.manager.modify(tunnel: row, with: rename)
            fail("the edit reported success while both the save and the re-read were refused")
            return
        } catch {
            guard case TunnelManagementError.vpnSystemErrorOnModifyTunnel = error else {
                fail("the refused pair surfaced as \(error) rather than the modify case")
                return
            }
        }

        check(rig.provider.loadCount == loadsBefore + 1,
              "the rollback re-read was issued and refused — loads=\(rig.provider.loadCount), expected \(loadsBefore + 1); "
              + "without this the checks below hold just as well against a rollback that was never written")
        check(rig.provider.saveCount == 1,
              "the edit reached the system exactly once and was refused there — saves=\(rig.provider.saveCount), expected 1")
        // The store's side of the state, PRINTED rather than asserted.
        // With the save refused nothing writes `storedDescription`, so
        // it still holds what the rig's constructor put there and no
        // production change can move it — which is exactly why it must
        // not be a `check`: a green line no regression can break reads
        // as coverage in the ledger. It is worth printing because the
        // three-way disagreement below is only legible with the
        // system's copy named beside the other two.
        log("the system's copy is where the rig left it — stored='\(rig.provider.storedDescription ?? "nil")', "
            + "the name the row came in with ('\(originalName)')")
        check(rig.provider.localizedDescription == newName,
              "a refused re-read paints nothing, so the projection is left holding the name this process wrote")
        check(rig.provider.tunnelIdentity?.name == newName,
              "identity included — and that is the field the realign's drift test reads, so this is the reading that "
              + "makes the sentence below a measurement rather than a story")
        check(vault.storedConfigs.last(where: { $0.id == rig.config.id })?.name == newName,
              "the vault took the EDIT, not merely a write for this id — so payload and projection now AGREE on a name "
              + "the system never accepted")
        log("the realign compares those two values and they are equal here, so its drift test has nothing to fire on for "
            + "this row until something else reads or writes the provider's preferences")
    }

    /// An edit arriving while the row is being removed is answered with
    /// an error, and nothing of it reaches either store.
    ///
    /// The removal is held at the vault read that chooses which store to
    /// empty first. That is not its first suspension — it waits on any
    /// activation rung and pending disarm before it, which on this rig
    /// resolve at once and write nothing, since neither exists — but it
    /// IS the last point before the removal touches a store. That
    /// placement is what makes the counters below mean what they say: a
    /// zero here is "the edit wrote nothing", uncontaminated by writes
    /// the removal itself would issue further down.
    ///
    /// Of the three counters read, only `saveCount` is one the removal
    /// would move once it resumes, through its own stand-down. The
    /// vault ledger and the projection are untouched by a removal at
    /// all: it deletes rather than stores, and never writes an identity.
    ///
    /// The refusal is a THROW rather than a silent no-op, and that is
    /// the contract production states in this exact spot: an edit
    /// landing inside a removal can restore the secret just erased or
    /// save an entry back over one already taken, and a save the user
    /// asked for deserves an answer. A second REMOVAL is the silent
    /// case; an edit is not.
    private func anEditIsRefusedDuringARemoval() async {
        let vault = answeringVault()
        guard let rig = rig(name: "TE-Edit-Removing-\(runTag)", vault: vault) else {
            fail("the config factory did not produce the throwaway this step needs")
            return
        }
        guard let row = rig.manager.tunnels.first(where: { $0.id == rig.config.id }) else {
            fail("the side manager did not materialize the listed tunnel")
            return
        }
        let originalName = rig.config.name
        let rename = edited(rig.config, to: "TE-Edit-Removing-New-\(runTag)")

        // The removal's order-choosing read, held open. The answer it
        // eventually gets is `.config`, the ordinary verdict, so the
        // removal that resumes is the ordinary one.
        //
        // Eight seconds against a three-second wait for the bar, and
        // the margin is the point rather than padding: everything this
        // step counts is a store the REMOVAL also writes once it
        // resumes, so a window that closed early would have the step
        // attributing the removal's own disarm and entry removal to the
        // edit. The bar is set on `remove()`'s first line, before that
        // read, so the wait below is ordinarily one poll long.
        vault.readAnswers = [rig.config.id: .answersAfter(seconds: 8, .config(rig.config))]
        let removal = Task { try await rig.manager.remove(tunnel: row) }

        guard await settle(within: 3, until: { rig.manager.removingIds.contains(rig.config.id) }) else {
            skip("environment: the removal never reached its bar")
            _ = await removal.result
            return
        }
        let savesBefore = rig.provider.saveCount
        let storedBefore = vault.storedIds.count

        do {
            try await rig.manager.modify(tunnel: row, with: rename)
            fail("the edit was accepted over a row a removal already holds")
            _ = await removal.result
            return
        } catch {
            guard case TunnelManagementError.vpnSystemErrorOnModifyTunnel = error else {
                fail("the barred edit surfaced as \(error) rather than the modify case")
                _ = await removal.result
                return
            }
        }

        // Read the counters only while the removal is provably still
        // parked. Once it resumes it writes both stores itself — the
        // disarm, then the entry — and a count taken after that cannot
        // say which call it belongs to. This is a named environment
        // exit rather than a failure: a machine slow enough to spend
        // the whole window before the edit returns has not shown the
        // bar to be broken, it has stopped the step from asking.
        guard rig.manager.removingIds.contains(rig.config.id) else {
            skip("environment: the held removal resumed before the counters could be read")
            _ = await removal.result
            return
        }
        check(vault.storedIds.count == storedBefore,
              "and nothing of it reached the vault — stores=\(vault.storedIds.count), expected \(storedBefore)")
        check(rig.provider.saveCount == savesBefore,
              "nor the system — saves=\(rig.provider.saveCount), expected \(savesBefore)")
        check(rig.provider.localizedDescription == originalName,
              "the projection was never moved, so the removal below is emptying the row it read")

        _ = await removal.result
    }

    /// The name guard, driven from both sides in one pass.
    ///
    /// The half that refuses proves the comparison is
    /// case-insensitive; the half that succeeds proves it excludes the
    /// row's OWN id. Either alone is satisfied by a broken guard — one
    /// by a guard that refuses everything, the other by a guard that
    /// refuses nothing — so neither is written without the other.
    private func aTakenNameIsRefusedAndItsOwnIsNot() async {
        let vault = answeringVault()
        guard let subject = TestConfigFactory.throwaway(name: "TE-Edit-Naming-\(runTag)"),
              let neighbour = TestConfigFactory.throwaway(name: "TE-Edit-Neighbour-\(runTag)") else {
            fail("the config factory did not produce the two throwaways this step needs")
            return
        }
        // Built here rather than through the single-row rig: this step
        // needs two listed rows under ONE manager, and a rig's spare
        // manager holding the same provider would leave it ambiguous
        // which list the guard below is reading.
        let editing = FakeSlotProvider(name: subject.name, identity: subject.identity, status: .disconnected)
        let other = FakeSlotProvider(name: neighbour.name, identity: neighbour.identity, status: .disconnected)
        let manager = TunnelsManager(
            tunnelProviders: [editing, other],
            providerFactory: FakeSlotFactory(canned: [editing, other]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let row = manager.tunnels.first(where: { $0.id == subject.id }),
              manager.tunnels.contains(where: { $0.id == neighbour.id }) else {
            fail("the side manager did not materialize both listed tunnels")
            return
        }

        do {
            try await manager.modify(tunnel: row, with: edited(subject, to: neighbour.name.uppercased()))
            fail("an edit took a name another row already holds")
            return
        } catch {
            guard case TunnelManagementError.tunnelAlreadyExistsWithThatName = error else {
                fail("the taken name surfaced as \(error) rather than the name-collision case")
                return
            }
        }
        check(editing.saveCount == 0,
              "and it was refused before either store was written — saves=\(editing.saveCount), expected 0")
        check(vault.storedIds.isEmpty,
              "the vault included — stores=\(vault.storedIds.count), expected 0")

        // Its own name, spelled differently. The guard excludes the
        // row's own id, so this is an ordinary edit and must go
        // through.
        let ownName = subject.name.uppercased()
        let loadsBefore = editing.loadCount
        do {
            try await manager.modify(tunnel: row, with: edited(subject, to: ownName))
        } catch {
            fail("a row was refused its own name: \(error.localizedDescription)")
            return
        }
        check(row.name == ownName,
              "the same guard let a row re-take the name it already had — the exclusion is by id, not by spelling")
        // The success path's own re-read, which had no witness anywhere:
        // `modify()` follows its save with a `loadPreferences()` inside
        // the `do`, and deleting that line changes no value this file
        // reads — only this count.
        check(editing.loadCount == loadsBefore + 1,
              "and the edit read the store back after writing it — loads=\(editing.loadCount), expected \(loadsBefore + 1)")

        // The success arm's three writes, read on the object the system
        // kept — the only place in the engine they are read AFTER a
        // save that landed. (`modify()` is driven to completion in one
        // other place, `VaultIntegrityWorkflow+CustodyReads`'s dedup
        // step, but as an arrangement: it asserts what the purge did,
        // never what the edit left on the provider.)
        //
        // Of the three, `isEnabled` (the `isEnabled = true` line in
        // `modify()`'s success arm) is the
        // one whose deletion nothing else in the engine would catch.
        // `configure(with:)` is also bound by the refused-rollback
        // step, through the process's copy rather than the store;
        // `localizedDescription` by both. The row's own name comes from
        // a separate assignment past all three, so it guards none of
        // them.
        check(editing.storedDescription == ownName,
              "and the edit LANDED in the system rather than only in this process — stored='\(editing.storedDescription ?? "nil")'")
        check(editing.storedIdentity?.name == ownName,
              "identity with it, which is what the next reload matches the row by and what the realign compares against the vault")
        check(editing.isEnabled,
              "with the manager left enabled — read on this process's copy, since the fake models the store for the projection "
              + "but not for this flag")
    }

    /// A name that is only whitespace is refused, and refused before
    /// anything is written.
    ///
    /// The trim is the whole claim: the string here is not empty, it
    /// becomes empty. A guard reading the raw value would accept it and
    /// the user would end up with a tunnel that has no name in either
    /// store.
    private func aBlankNameIsRefusedBeforeAnyWrite() async {
        let vault = answeringVault()
        guard let rig = rig(name: "TE-Edit-Blank-\(runTag)", vault: vault) else {
            fail("the config factory did not produce the throwaway this step needs")
            return
        }
        guard let row = rig.manager.tunnels.first(where: { $0.id == rig.config.id }) else {
            fail("the side manager did not materialize the listed tunnel")
            return
        }
        let originalName = rig.config.name

        do {
            try await rig.manager.modify(tunnel: row, with: edited(rig.config, to: "   \n\t "))
            fail("an edit took a name that is only whitespace")
            return
        } catch {
            guard case TunnelManagementError.tunnelInvalidName = error else {
                fail("the blank name surfaced as \(error) rather than the invalid-name case")
                return
            }
        }

        check(vault.storedIds.isEmpty,
              "the vault was never written — stores=\(vault.storedIds.count), expected 0")
        check(rig.provider.saveCount == 0,
              "nor the system — saves=\(rig.provider.saveCount), expected 0")
        check(row.name == originalName,
              "and the row keeps the name it had")
    }
}
#endif
