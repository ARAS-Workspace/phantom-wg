// Tunnel Remove
//
// The REMOVE path: the order in which `remove()` lets go of the system
// entry and of the Keychain item that entry references.
//
// Everything here runs over a `TunnelsManager` of the step's own, whose
// listed row is a `FakeSlotProvider` handed both as the opening row and as
// the factory's canned answer. Nothing reaches the user's list or the
// system.
//
// Scenarios:
//
//   A — A Refused Removal Leaves The Saved Tunnel Readable
//       The row's configuration is sealed into the app group Keychain by
//       the production `configure(with:)` path (`.keychain` storage), and
//       the system refuses the removal. The removal is refused as a system
//       error carrying the system's refusal, and its text is the removal's
//       sentence carrying the system's words. The row is still listed and
//       the system store still holds the entry. Then the provider is read
//       back from what the system stored — what the next reload or the next
//       launch reads — and the claim is that it still opens the
//       configuration that was saved. Every Keychain item the step created
//       is deleted on the way out.
//
//   B — An Accepted Removal Leaves No Keychain Item
//       The same planting, and the system accepts the removal. The
//       removal lands, the row is out of the list and the system store
//       holds no entry for it, and the item the entry referenced opens
//       nothing.

#if DEBUG
import Foundation

final class TunnelRemoveWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Remove (What A Removal Leaves)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("A Refused Removal Leaves The Saved Tunnel Readable", aRefusedRemovalLeavesTheSavedTunnelReadable),
            WorkflowStep("An Accepted Removal Leaves No Keychain Item", anAcceptedRemovalLeavesNoKeychainItem)
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))
    private let refusal = NSError(domain: "TE.Fake", code: 7,
                                  userInfo: [NSLocalizedDescriptionKey: "test rig refused the removal"])

    // MARK: - Steps

    func aRefusedRemovalLeavesTheSavedTunnelReadable() async {
        guard let original = TestConfigFactory.throwaway(name: "TE-Remove-Keychain-\(runTag)") else {
            fail("the config factory produced no throwaway")
            return
        }
        let provider = FakeSlotProvider(storage: .keychain, config: original)
        onTeardown("delete the step's Keychain items") { provider.sweepKeychain() }
        let read = provider.tunnelConfig
        guard check(read == original,
                    "the planted row reads its configuration back from the app group Keychain"
                    + " (sealed=\(provider.keychainRef != nil), reads \(read.map { "\"\($0.name)\"" } ?? "nothing"))") else { return }
        let manager = TunnelsManager(tunnelProviders: [provider], providerFactory: FakeSlotFactory(canned: [provider]))
        guard let row = manager.tunnels.first else {
            fail("the planted row is not in the step's list")
            return
        }

        provider.removeAnswer = .fails(refusal)
        var refused: Error?
        do {
            try await manager.remove(tunnel: row)
        } catch {
            refused = error
        }
        var carriesTheRefusal = false
        if let refused, case TunnelManagementError.vpnSystemErrorOnRemoveTunnel(let carried) = refused {
            carriesTheRefusal = (carried as NSError) == refusal
        }
        check(carriesTheRefusal,
              "the removal the system refused is refused as a system error carrying the system's refusal"
              + " (\(String(describing: refused)))")
        let sentence = LocalizationManager.shared.t("error_remove_tunnel", refusal.localizedDescription)
        check(refused?.localizedDescription == sentence,
              "the refusal reads as the removal's sentence carrying the system's words"
              + " (\(refused?.localizedDescription ?? "nothing"))")
        check(manager.tunnels.contains { $0.id == original.id } && provider.entryExists,
              "the row is still listed and the system store still holds the entry"
              + " (rows=\(manager.tunnels.count), entry=\(provider.entryExists))")

        try? await provider.loadPreferences()
        let stored = provider.tunnelConfig
        check(stored == original,
              "read back from what the system stored, the tunnel still opens the configuration that was saved"
              + " (reads \(stored.map { "\"\($0.name)\"" } ?? "nothing"))")
    }

    func anAcceptedRemovalLeavesNoKeychainItem() async {
        guard let original = TestConfigFactory.throwaway(name: "TE-Remove-Accepted-\(runTag)") else {
            fail("the config factory produced no throwaway")
            return
        }
        let provider = FakeSlotProvider(storage: .keychain, config: original)
        onTeardown("delete the step's Keychain items") { provider.sweepKeychain() }
        let read = provider.tunnelConfig
        guard check(read == original && provider.keychainRefs.count == 1,
                    "the planted row reads its configuration back from its one app group Keychain item"
                    + " (items=\(provider.keychainRefs.count), reads \(read.map { "\"\($0.name)\"" } ?? "nothing"))") else { return }
        let manager = TunnelsManager(tunnelProviders: [provider], providerFactory: FakeSlotFactory(canned: [provider]))
        guard let row = manager.tunnels.first else {
            fail("the planted row is not in the step's list")
            return
        }

        var outcome: Error?
        do {
            try await manager.remove(tunnel: row)
        } catch {
            outcome = error
        }
        guard check(outcome == nil, "the removal the system accepted lands (\(String(describing: outcome)))") else { return }
        check(!manager.tunnels.contains { $0.id == original.id } && !provider.entryExists,
              "the row is out of the list and the system store holds no entry for it"
              + " (rows=\(manager.tunnels.count), entry=\(provider.entryExists))")
        let open = provider.keychainRefs.filter { Keychain.openReference(called: $0) != nil }
        check(open.isEmpty, "the item the entry referenced opens nothing (open=\(open.count))")
    }
}
#endif
