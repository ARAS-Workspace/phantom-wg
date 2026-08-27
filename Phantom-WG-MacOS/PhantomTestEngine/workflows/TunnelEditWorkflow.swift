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
//   G — An Edit Is Refused When A Removal Finished Inside Its Window
//       D's bar read on entry goes stale across the vault write: a removal
//       that COMPLETED inside that window has already left `removingIds`,
//       so it is the list alone the re-read must notice.
//   H — A Name Taken Inside The Edit's Window Is Refused
//       E's reading, re-taken past the vault write: a concurrent add can
//       claim the name while the edit's store is in flight. The refusal
//       leaves the vault holding the edit — the declared drift.

#if DEBUG
import Foundation
import NetworkExtension

final class TunnelEditWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Edit (Refusals + The Projection Rollback)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("An Edit The Vault Refuses Never Reaches The System",
                         aRefusedEditNeverReachesTheSystem),
            WorkflowStep("A Failed Save Puts The Projection Back",
                         aFailedSavePutsTheProjectionBack),
            WorkflowStep("A Rollback The System Refuses Leaves The Projection Agreeing With The Vault",
                         aRefusedRollbackLeavesTheProjectionAgreeingWithTheVault),
            WorkflowStep("An Edit Is Refused While The Row Is Being Removed",
                         anEditIsRefusedDuringARemoval),
            WorkflowStep("A Name Another Row Holds Is Refused, Its Own Is Not",
                         aTakenNameIsRefusedAndItsOwnIsNot),
            WorkflowStep("A Blank Name Is Refused Before Either Store Is Touched",
                         aBlankNameIsRefusedBeforeAnyWrite),
            WorkflowStep("An Edit Is Refused When A Removal Finished Inside Its Window",
                         anEditIsRefusedAfterARemovalCrossedItsWindow),
            WorkflowStep("A Name Taken Inside The Edit's Window Is Refused",
                         aNameTakenInsideTheEditsWindowIsRefused),
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))

    // MARK: - Rig

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
        check(rig.provider.tunnelIdentity?.name == originalName,
              "identity included, so the rollback left no half-repainted projection behind — though only the refused-rollback "
              + "step can tell this apart from an identity that was never moved")
        check(row.name == originalName,
              "the row keeps its old name, since the line that renames it is past the throw")

        check(vault.storedConfigs.last(where: { $0.id == rig.config.id })?.name == newName,
              "while the vault holds the EDIT itself — the drift is real, and the projection above is what leaves it detectable")
    }

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

    private func aTakenNameIsRefusedAndItsOwnIsNot() async {
        let vault = answeringVault()
        guard let subject = TestConfigFactory.throwaway(name: "TE-Edit-Naming-\(runTag)"),
              let neighbour = TestConfigFactory.throwaway(name: "TE-Edit-Neighbour-\(runTag)") else {
            fail("the config factory did not produce the two throwaways this step needs")
            return
        }
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
        check(editing.loadCount == loadsBefore + 1,
              "and the edit read the store back after writing it — loads=\(editing.loadCount), expected \(loadsBefore + 1)")

        check(editing.storedDescription == ownName,
              "and the edit LANDED in the system rather than only in this process — stored='\(editing.storedDescription ?? "nil")'")
        check(editing.storedIdentity?.name == ownName,
              "identity with it, which is what the next reload matches the row by and what the realign compares against the vault")
        check(editing.isEnabled,
              "with the manager left enabled — read on this process's copy, since the fake models the store for the projection "
              + "but not for this flag")
    }

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

    private func anEditIsRefusedAfterARemovalCrossedItsWindow() async {
        let vault = answeringVault()
        guard let rig = rig(name: "TE-Edit-CrossedRemoval-\(runTag)", vault: vault) else {
            fail("the config factory did not produce the throwaway this step needs")
            return
        }
        guard let row = rig.manager.tunnels.first(where: { $0.id == rig.config.id }) else {
            fail("the side manager did not materialize the listed tunnel")
            return
        }
        let rename = edited(rig.config, to: "TE-Edit-CrossedRemoval-New-\(runTag)")

        // The removal's own reads answer at once; the edit's vault write is
        // the slow one, so the removal can run to completion INSIDE it.
        vault.readAnswer = .answers(.missing)
        vault.storeAnswer = .answersAfter(seconds: 2, .done)

        let edit = Task { @MainActor () -> Error? in
            do { try await rig.manager.modify(tunnel: row, with: rename); return nil } catch { return error }
        }
        guard await settle(within: 1.5, until: { vault.storedIds.contains(rig.config.id) }) else {
            skip("environment: the edit never reached its vault write")
            _ = await edit.value
            return
        }

        guard let removed = await race(1.5, { (try? await rig.manager.remove(tunnel: row)) != nil }),
              removed else {
            fail("the removal did not run to completion inside the edit's vault-store window")
            _ = await edit.value
            return
        }
        guard check(!rig.manager.removingIds.contains(rig.config.id)
                        && !rig.manager.tunnels.contains(where: { $0 === row }),
                    "the removal FINISHED inside the window: not in flight any more and the row gone from"
                    + " the list — so the list alone is what the re-read below has to notice") else {
            _ = await edit.value
            return
        }

        guard let thrown = await race(5, { await edit.value }) else {
            fail("the edit never returned past its window")
            return
        }
        var refused = false
        if case TunnelManagementError.vpnSystemErrorOnModifyTunnel? = thrown { refused = true }
        check(refused,
              "the edit re-read its bar past the vault write and refused — the session-ended class, not a"
              + " success over a row a removal emptied"
              + " (error=\(thrown.map { String(describing: $0) } ?? "nil"))")
        check(rig.provider.saveCount == 1,
              "the system store holds only the removal's own stand-down — the edit's save never went out"
              + " (saves=\(rig.provider.saveCount))")
        check(rig.provider.removeCount == 1,
              "the entry went once, to the removal (removes=\(rig.provider.removeCount))")
        check(rig.provider.localizedDescription == rig.config.name,
              "and the refused edit never repainted the projection")
    }

    private func aNameTakenInsideTheEditsWindowIsRefused() async {
        let vault = answeringVault()
        guard let subject = TestConfigFactory.throwaway(name: "TE-Edit-WindowName-\(runTag)"),
              let arrival = TestConfigFactory.throwaway(name: "TE-Edit-WindowArrival-\(runTag)") else {
            fail("the config factory did not produce the two throwaways this step needs")
            return
        }
        let editing = FakeSlotProvider(name: subject.name, identity: subject.identity, status: .disconnected)
        let manager = TunnelsManager(
            tunnelProviders: [editing],
            providerFactory: FakeSlotFactory(canned: [editing]),
            vault: vault,
            observesSystemChanges: false
        )
        guard let row = manager.tunnels.first(where: { $0.id == subject.id }) else {
            fail("the side manager did not materialize the listed tunnel")
            return
        }
        let contested = "TE-Edit-Contested-\(runTag)"

        vault.storeAnswer = .answersAfter(seconds: 2, .done)
        let edit = Task { @MainActor () -> Error? in
            do {
                try await manager.modify(tunnel: row, with: edited(subject, to: contested))
                return nil
            } catch { return error }
        }
        guard await settle(within: 1.5, until: { vault.storedIds.contains(subject.id) }) else {
            skip("environment: the edit never reached its vault write")
            _ = await edit.value
            return
        }

        // The arriving add answers at once; the edit's own store call is
        // already sleeping on the answer it captured.
        vault.storeAnswer = .answers(.done)
        var renamedArrival = arrival
        renamedArrival.name = contested
        guard let added = await race(1.5, { (try? await manager.add(config: renamedArrival)) != nil }),
              added else {
            fail("the concurrent add could not take the contested name inside the edit's window")
            _ = await edit.value
            return
        }

        guard let thrown = await race(5, { await edit.value }) else {
            fail("the edit never returned past its window")
            return
        }
        var named = false
        if case TunnelManagementError.tunnelAlreadyExistsWithThatName? = thrown { named = true }
        check(named,
              "the edit re-read the name past its vault write and refused the clash it found there"
              + " (error=\(thrown.map { String(describing: $0) } ?? "nil"))")
        check(editing.saveCount == 0,
              "so the edit's save never reached the system store (saves=\(editing.saveCount))")
        check(editing.localizedDescription == subject.name && row.name == subject.name,
              "and neither the projection nor the row was repainted")
        check(vault.storedConfigs.last(where: { $0.id == subject.id })?.name == contested,
              "while the vault HOLDS the edit — the declared drift, left for the realign whose own name"
              + " bar refuses the projection write while the clash stands")
    }
}
#endif
