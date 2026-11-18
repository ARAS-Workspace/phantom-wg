// Tunnel Edit
//
// The EDIT path: what `modify()` refuses, and what it leaves behind when
// the system refuses or accepts its save.
//
// Everything here runs over a `TunnelsManager` of the step's own, whose
// listed rows are `FakeSlotProvider`s handed both as the opening rows and
// as the factory's canned answer, so a reload that rebuilds the list finds
// the same objects. Nothing reaches the user's list or the system.
//
// Scenarios:
//
//   A — A Name Another Row Holds Is Refused, Its Own Is Not
//       An edit to another row's name, in other letter case, is refused as
//       a name clash before the system is asked; an edit to the row's own
//       name in other letter case lands and the row carries it.
//
//   B — A Blank Name Is Refused Before The System Is Touched
//       A name of spaces is refused as an invalid name; no save is issued
//       and the row and its configuration are as they were.
//
//   C — A Refused Save Leaves The Saved Tunnel Readable
//       The row's configuration is sealed into the app group Keychain by
//       the production `configure(with:)` path (`.keychain` storage), and
//       the system refuses the edit's save. The edit is refused as a
//       system error and the row keeps its name; the provider in memory is
//       back on the saved configuration and its item, and of the items the
//       step's provider referenced only the saved one opens. Then the
//       provider is read back from what the system stored — what the next
//       reload or the next launch reads — and the claim is that it still
//       opens the configuration that was saved. Every Keychain item the
//       step created is deleted on the way out.
//
//   D — An Accepted Save Leaves Only The Item It Sealed
//       The same planting, and the system accepts the edit's save. The
//       edit lands and the row carries the edited name; read back from
//       what the system stored, the tunnel opens the edit, and of the
//       items the step's provider referenced only the one the edit sealed
//       opens — the item it replaced is deleted.

#if DEBUG
import Foundation

final class TunnelEditWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Edit (Refusals And What A Save Leaves)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("A Name Another Row Holds Is Refused, Its Own Is Not", aTakenNameIsRefusedAndItsOwnIsNot),
            WorkflowStep("A Blank Name Is Refused Before The System Is Touched", aBlankNameIsRefusedBeforeTheSystemIsTouched),
            WorkflowStep("A Refused Save Leaves The Saved Tunnel Readable", aRefusedSaveLeavesTheSavedTunnelReadable),
            WorkflowStep("An Accepted Save Leaves Only The Item It Sealed", anAcceptedSaveLeavesOnlyTheItemItSealed)
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))
    private let refusal = NSError(domain: "TE.Fake", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey: "test rig refused the save"])

    /// The references among `provider.keychainRefs` whose item still opens.
    private func opening(_ provider: FakeSlotProvider) -> [Data] {
        provider.keychainRefs.filter { Keychain.openReference(called: $0) != nil }
    }

    private func outcome(_ manager: TunnelsManager, _ row: TunnelContainer, _ config: TunnelConfig) async -> Error? {
        do {
            try await manager.modify(tunnel: row, with: config)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Steps

    func aTakenNameIsRefusedAndItsOwnIsNot() async {
        guard let configA = TestConfigFactory.throwaway(name: "TE-Edit-A-\(runTag)"),
              let configB = TestConfigFactory.throwaway(name: "TE-Edit-B-\(runTag)") else {
            fail("the config factory did not produce the two throwaways this step needs")
            return
        }
        let providerA = FakeSlotProvider(config: configA)
        let providerB = FakeSlotProvider(config: configB)
        let manager = TunnelsManager(tunnelProviders: [providerA, providerB],
                                     providerFactory: FakeSlotFactory(canned: [providerA, providerB]))
        guard let rowA = manager.tunnels.first(where: { $0.id == configA.id }) else {
            fail("the planted row A is not in the step's list")
            return
        }

        var taken = configA
        taken.name = configB.name.lowercased()
        let clash = await outcome(manager, rowA, taken)
        var refusedAsClash = false
        if let clash, case TunnelManagementError.tunnelAlreadyExistsWithThatName = clash { refusedAsClash = true }
        check(refusedAsClash, "an edit to another row's name in other letter case is refused as a name clash (\(String(describing: clash)))")
        check(providerA.saveCount == 0 && rowA.name == configA.name && providerA.tunnelConfig?.name == configA.name,
              "before the system is asked: no save, and the row and its configuration keep their name (saves=\(providerA.saveCount))")

        var own = configA
        own.name = configA.name.uppercased()
        let ownOutcome = await outcome(manager, rowA, own)
        check(ownOutcome == nil, "an edit to the row's own name in other letter case lands (\(String(describing: ownOutcome)))")
        check(rowA.name == own.name && providerA.saveCount == 1,
              "the row carries the new letter case after one save (name=\(rowA.name), saves=\(providerA.saveCount))")
    }

    func aBlankNameIsRefusedBeforeTheSystemIsTouched() async {
        guard let config = TestConfigFactory.throwaway(name: "TE-Edit-Blank-\(runTag)") else {
            fail("the config factory produced no throwaway")
            return
        }
        let provider = FakeSlotProvider(config: config)
        let manager = TunnelsManager(tunnelProviders: [provider], providerFactory: FakeSlotFactory(canned: [provider]))
        guard let row = manager.tunnels.first else {
            fail("the planted row is not in the step's list")
            return
        }
        var blank = config
        blank.name = "   "
        let refused = await outcome(manager, row, blank)
        var invalidName = false
        if let refused, case TunnelManagementError.tunnelInvalidName = refused { invalidName = true }
        check(invalidName, "a name of spaces is refused as an invalid name (\(String(describing: refused)))")
        check(provider.saveCount == 0 && row.name == config.name && provider.tunnelConfig == config,
              "no save was issued and the row and its configuration are as they were (saves=\(provider.saveCount))")
    }

    func aRefusedSaveLeavesTheSavedTunnelReadable() async {
        guard let original = TestConfigFactory.throwaway(name: "TE-Edit-Keychain-\(runTag)") else {
            fail("the config factory produced no throwaway")
            return
        }
        let provider = FakeSlotProvider(storage: .keychain, config: original)
        onTeardown("delete the step's Keychain items") { provider.sweepKeychain() }
        guard let savedRef = provider.keychainRef else {
            fail("the planted row carries no Keychain reference")
            return
        }
        guard check(provider.tunnelConfig == original,
                    "the planted row reads its configuration back from the app group Keychain") else { return }
        let manager = TunnelsManager(tunnelProviders: [provider], providerFactory: FakeSlotFactory(canned: [provider]))
        guard let row = manager.tunnels.first else {
            fail("the planted row is not in the step's list")
            return
        }

        var edited = original
        edited.name = "\(original.name)-Edited"
        provider.saveAnswer = .fails(refusal)
        let refused = await outcome(manager, row, edited)
        var asSystemError = false
        if let refused, case TunnelManagementError.vpnSystemErrorOnModifyTunnel = refused { asSystemError = true }
        check(asSystemError, "the edit whose save the system refused is refused as a system error (\(String(describing: refused)))")
        check(row.name == original.name, "the row keeps its name (name=\(row.name))")
        check(provider.tunnelConfig == original && provider.keychainRef == savedRef
                && provider.localizedDescription == original.name,
              "the provider in memory is back on the saved configuration, its item and its name"
              + " (reads \(provider.tunnelConfig.map { "\"\($0.name)\"" } ?? "nothing"))")
        let open = opening(provider)
        check(open == [savedRef],
              "of the \(provider.keychainRefs.count) items the step's provider referenced, only the saved one opens"
              + " (open=\(open.count), saved opens=\(open.contains(savedRef)))")

        provider.loadAnswer = .succeeds
        try? await provider.loadPreferences()
        let stored = provider.tunnelConfig
        check(stored == original,
              "read back from what the system stored, the tunnel still opens the configuration that was saved"
              + " (reads \(stored.map { "\"\($0.name)\"" } ?? "nothing"))")
    }

    func anAcceptedSaveLeavesOnlyTheItemItSealed() async {
        guard let original = TestConfigFactory.throwaway(name: "TE-Edit-Accepted-\(runTag)") else {
            fail("the config factory produced no throwaway")
            return
        }
        let provider = FakeSlotProvider(storage: .keychain, config: original)
        onTeardown("delete the step's Keychain items") { provider.sweepKeychain() }
        guard let savedRef = provider.keychainRef else {
            fail("the planted row carries no Keychain reference")
            return
        }
        guard check(provider.tunnelConfig == original,
                    "the planted row reads its configuration back from the app group Keychain") else { return }
        let manager = TunnelsManager(tunnelProviders: [provider], providerFactory: FakeSlotFactory(canned: [provider]))
        guard let row = manager.tunnels.first else {
            fail("the planted row is not in the step's list")
            return
        }

        var edited = original
        edited.name = "\(original.name)-Edited"
        let landed = await outcome(manager, row, edited)
        guard check(landed == nil, "the edit whose save the system accepted lands (\(String(describing: landed)))") else { return }
        check(row.name == edited.name, "the row carries the edited name (name=\(row.name))")

        try? await provider.loadPreferences()
        let stored = provider.tunnelConfig
        check(stored == edited,
              "read back from what the system stored, the tunnel opens the edit"
              + " (reads \(stored.map { "\"\($0.name)\"" } ?? "nothing"))")
        let open = opening(provider)
        check(open.count == 1 && open.first == provider.keychainRef && !open.contains(savedRef),
              "of the \(provider.keychainRefs.count) items the step's provider referenced, only the one the edit sealed opens"
              + " (open=\(open.count), replaced opens=\(open.contains(savedRef)))")
    }
}
#endif
