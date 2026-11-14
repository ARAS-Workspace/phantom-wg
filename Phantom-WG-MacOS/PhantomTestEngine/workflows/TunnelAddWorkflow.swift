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
// Tunnel Add
//
// The ADD path's name bar, measured across the window `add()` opens for
// itself.
//
// `add()` reads the list for the name twice: on entry, and again past its
// vault write. The row it creates reaches the list later still, after the
// provider's save and load have both answered. That last stretch is this
// file's subject: a second add of the same name, under another id, that
// arrives while the first is still waiting on the system.
//
// Everything here runs over fabricated stores: a vault that answers at
// once, and a factory that mints the providers `add()` asks for, the first
// of them told to answer its save late. Nothing reaches the user's list or
// the real vault.
//
// The vault's `readAll` starts empty and is switched, once the first add
// has stored, to answer with that one payload — what a real vault would
// say at that moment. The second add's deduplication therefore meets the
// first add's payload while its entry is still being created.
//
// Scenarios:
//
//   A — Two Adds Of One Name That Cross Leave One Row
//       The first add is held inside its provider save; the second is
//       started in that window. The claim is the outcome and not the
//       mechanism: one add lands, the other is refused as a name clash,
//       and the list, the system store and the vault each hold the name
//       once. The order the two returned in is logged and carries no
//       verdict, so a manager that makes the second add wait passes as
//       well as one that refuses it at once.

#if DEBUG
import Foundation

final class TunnelAddWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Add (The Name Bar Across Its Own Window)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Two Adds Of One Name That Cross Leave One Row",
                         twoAddsOfOneNameThatCrossLeaveOneRow),
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))
    private var returnOrder: [String] = []

    // MARK: - Rig

    private enum Outcome: Sendable {
        case landed
        case refused(Error)

        var label: String {
            switch self {
            case .landed: return "landed"
            case .refused(let error): return "refused(\(error))"
            }
        }
    }

    private func answeringVault() -> FaultVaultClient {
        let vault = FaultVaultClient()
        vault.readAllAnswer = .answers(.configs([]))
        vault.readAnswer = .answers(.unreachable)
        vault.storeAnswer = .answers(.done)
        vault.deleteAnswer = .answers(.done)
        return vault
    }

    private func attempt(_ label: String, _ manager: TunnelsManager, _ config: TunnelConfig) async -> Outcome {
        let outcome: Outcome
        do {
            _ = try await manager.add(config: config)
            outcome = .landed
        } catch {
            outcome = .refused(error)
        }
        returnOrder.append(label)
        return outcome
    }

    private func landed(_ outcome: Outcome) -> Bool {
        if case .landed = outcome { return true }
        return false
    }

    private func refusedAsNameClash(_ outcome: Outcome) -> Bool {
        guard case .refused(let error) = outcome,
              case TunnelManagementError.tunnelAlreadyExistsWithThatName = error else { return false }
        return true
    }

    // MARK: - Steps

    private func twoAddsOfOneNameThatCrossLeaveOneRow() async {
        let contested = "TE-Add-Contested-\(runTag)"
        guard let first = TestConfigFactory.throwaway(name: contested),
              let second = TestConfigFactory.throwaway(name: contested) else {
            fail("the config factory did not produce the two throwaways this step needs")
            return
        }
        let vault = answeringVault()
        let factory = FakeSlotFactory(canned: [])
        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: factory,
            vault: vault,
            observesSystemChanges: false
        )
        returnOrder = []

        factory.minted.saveAnswer = .succeedsAfter(seconds: 1.5)
        let held = Task { @MainActor in await self.attempt("first", manager, first) }
        guard await settle(within: 1.5, until: { factory.minted.providers.first?.saveCount == 1 }) else {
            skip("environment: the first add never reached its provider save")
            _ = await held.value
            return
        }
        guard check(first.id != second.id
                        && vault.storedIds.contains(first.id)
                        && manager.tunnels.isEmpty,
                    "the first add is waiting on its provider save: its payload is stored and its row is not"
                    + " in the list yet — the window this step is about"
                    + " (stored=\(vault.storedIds.count), rows=\(manager.tunnels.count))") else {
            _ = await held.value
            return
        }

        vault.readAllAnswer = .answers(.configs([first]))
        factory.minted.saveAnswer = .succeeds
        let crossing = Task { @MainActor in await self.attempt("second", manager, second) }

        guard let waited = await race(6, { await held.value }) else {
            fail("the first add never returned past its provider save")
            return
        }
        guard let crossed = await race(6, { await crossing.value }) else {
            fail("the second add never returned")
            return
        }
        log("returned in this order: \(returnOrder.joined(separator: ", then "))")

        let outcomes = [waited, crossed]
        let landings = outcomes.filter(landed).count
        let clashes = outcomes.filter(refusedAsNameClash).count
        let rows = manager.tunnels.filter { $0.name.caseInsensitiveCompare(contested) == .orderedSame }.count
        let entries = factory.minted.providers.filter(\.entryExists).count
        let payloads = Set(vault.storedIds).subtracting(vault.deletedIds).count

        check(landings == 1 && clashes == 1,
              "of two adds of one name that crossed, one landed and the other was refused as a name clash"
              + " (first=\(waited.label), second=\(crossed.label))")
        check(rows == 1,
              "the list holds the name once (rows=\(rows))")
        check(entries == 1,
              "the system store holds one entry for it"
              + " (entries=\(entries), minted=\(factory.minted.providers.count))")
        check(payloads == 1,
              "and the vault holds one payload for it: the refused add left none behind"
              + " (stored=\(vault.storedIds.count), deleted=\(vault.deletedIds.count))")
    }
}
#endif
