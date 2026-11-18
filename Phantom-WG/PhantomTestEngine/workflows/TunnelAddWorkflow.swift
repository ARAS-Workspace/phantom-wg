// Tunnel Add
//
// The ADD path's name bar, measured across the window `add()` opens for
// itself.
//
// `add()` reads the list for the name on entry. The row it creates reaches
// the list later, after the provider's save and load have both answered.
// That stretch is this file's subject.
//
// Everything here runs over a `TunnelsManager` of the step's own, over a
// `FakeSlotFactory` that mints the providers `add()` asks for. Nothing
// reaches the user's list or the system.
//
// Scenarios:
//
//   A — Two Adds Of One Name That Cross Leave One Row
//       The first add is held inside its provider save; the second is
//       started in that window. The claim is the outcome and not the
//       mechanism: one add lands, the other is refused as a name clash,
//       and the list and the system store each hold the name once. The
//       order the two returned in is logged and carries no verdict.
//
//   B — A Refused Save Leaves No Row And Frees The Name
//       The system refuses the first add's save: the add is refused as a
//       system error and lists nothing; a second add of the same name,
//       whose save the system takes, lands. A name the refused add held
//       through its window would refuse the second.
//
//   C — A Blank Name Is Refused Before A Provider Is Minted
//       A name of spaces is refused as an invalid name, and the factory
//       minted nothing.

#if DEBUG
import Foundation

final class TunnelAddWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Add (The Name Bar Across Its Own Window)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Two Adds Of One Name That Cross Leave One Row", twoAddsOfOneNameThatCrossLeaveOneRow),
            WorkflowStep("A Refused Save Leaves No Row And Frees The Name", aRefusedSaveLeavesNoRowAndFreesTheName),
            WorkflowStep("A Blank Name Is Refused Before A Provider Is Minted", aBlankNameIsRefusedBeforeAProviderIsMinted)
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))
    private var returnOrder: [String] = []

    // MARK: - Rig

    private enum Outcome {
        case landed
        case refused(Error)

        var label: String {
            switch self {
            case .landed: return "landed"
            case .refused(let error): return "refused(\(error))"
            }
        }
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

    private func rows(named name: String, in manager: TunnelsManager) -> Int {
        manager.tunnels.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.count
    }

    // MARK: - Steps

    func twoAddsOfOneNameThatCrossLeaveOneRow() async {
        let contested = "TE-Add-Contested-\(runTag)"
        guard let first = TestConfigFactory.throwaway(name: contested),
              let second = TestConfigFactory.throwaway(name: contested) else {
            fail("the config factory did not produce the two throwaways this step needs")
            return
        }
        let factory = FakeSlotFactory(canned: [])
        let manager = TunnelsManager(tunnelProviders: [], providerFactory: factory)
        returnOrder = []

        factory.minted.saveAnswer = .succeedsAfter(seconds: 1.5)
        let held = Task { @MainActor in await self.attempt("first", manager, first) }
        guard await settle(within: 1.5, until: { factory.minted.providers.first?.saveCount == 1 }) else {
            skip("environment: the first add never reached its provider save")
            _ = await held.value
            return
        }
        guard check(first.id != second.id && manager.tunnels.isEmpty,
                    "the first add is waiting on its provider save and its row is not in the list yet"
                    + " — the window this step is about (rows=\(manager.tunnels.count))") else {
            _ = await held.value
            return
        }

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
        let entries = factory.minted.providers.filter(\.entryExists).count
        check(outcomes.filter(landed).count == 1 && outcomes.filter(refusedAsNameClash).count == 1,
              "of two adds of one name that crossed, one landed and the other was refused as a name clash"
              + " (first=\(waited.label), second=\(crossed.label))")
        check(rows(named: contested, in: manager) == 1,
              "the list holds the name once (rows=\(rows(named: contested, in: manager)))")
        check(entries == 1,
              "the system store holds one entry for it (entries=\(entries), minted=\(factory.minted.providers.count))")
    }

    func aRefusedSaveLeavesNoRowAndFreesTheName() async {
        let name = "TE-Add-Refused-\(runTag)"
        guard let refused = TestConfigFactory.throwaway(name: name),
              let retried = TestConfigFactory.throwaway(name: name) else {
            fail("the config factory did not produce the two throwaways this step needs")
            return
        }
        let factory = FakeSlotFactory(canned: [])
        let manager = TunnelsManager(tunnelProviders: [], providerFactory: factory)

        factory.minted.saveAnswer = .fails(NSError(domain: "TE.Fake", code: 5,
                                                   userInfo: [NSLocalizedDescriptionKey: "test rig refused the save"]))
        let first = await attempt("refused", manager, refused)
        var refusedAsSystem = false
        if case .refused(let error) = first, case TunnelManagementError.vpnSystemErrorOnAddTunnel = error {
            refusedAsSystem = true
        }
        check(refusedAsSystem, "the add whose save the system refused is refused as a system error (\(first.label))")
        check(manager.tunnels.isEmpty, "and it lists nothing (rows=\(manager.tunnels.count))")

        factory.minted.saveAnswer = .succeeds
        let second = await attempt("retried", manager, retried)
        check(landed(second), "a second add of the same name lands — the refused add left the name free (\(second.label))")
        check(rows(named: name, in: manager) == 1, "the list holds the name once (rows=\(rows(named: name, in: manager)))")
    }

    func aBlankNameIsRefusedBeforeAProviderIsMinted() async {
        // validate() refuses a blank name itself, so the blank is written
        // into a config that already passed it — the way a caller other
        // than the import screen could hand one to add().
        guard var blank = TestConfigFactory.throwaway(name: "TE-Add-Blank-\(runTag)") else {
            fail("the config factory produced no throwaway")
            return
        }
        blank.name = "   "
        let factory = FakeSlotFactory(canned: [])
        let manager = TunnelsManager(tunnelProviders: [], providerFactory: factory)
        let outcome = await attempt("blank", manager, blank)
        var invalidName = false
        if case .refused(let error) = outcome, case TunnelManagementError.tunnelInvalidName = error {
            invalidName = true
        }
        check(invalidName, "a name of spaces is refused as an invalid name (\(outcome.label))")
        check(factory.minted.providers.isEmpty && manager.tunnels.isEmpty,
              "and the factory minted nothing (minted=\(factory.minted.providers.count), rows=\(manager.tunnels.count))")
    }
}
#endif
