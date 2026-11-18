// Tunnel Load
//
// The LAUNCH path: what `TunnelsManager.create()` does with the app group
// Keychain while it loads the system's tunnel entries.
//
// Unlike the other families, the step here runs the production
// `create()` itself, over the system the app runs on (the simulated
// Network Extension on the simulator, the real one on a device): the set
// of items a launch may touch is decided by the entries that system
// lists, and a fake list would decide it wrongly. `create()` builds a
// manager of the step's own, which is dropped when the step returns.
//
// Scenarios:
//
//   A — An Item No Entry References Is Collected At Launch
//       A first `create()` counts the listed entries that read their
//       configuration, and adds a `Test-` entry of the step's own through
//       it, so the system holds one entry this step answers for. Then an
//       item that no entry references is sealed through
//       `Keychain.makeReference` (a throwaway value, no secret), and a
//       second `create()` runs. The claims are that the item opens
//       nothing afterwards, that the step's own entry still reads its
//       configuration, and that the entries read before still read it.
//       Whether the step entry's stored reference equals the form the
//       Keychain hands back for it is logged. The item and the `Test-`
//       entry are deleted on the way out.

#if DEBUG
import Foundation
import NetworkExtension
import Security

final class TunnelLoadWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Load (What A Launch Collects)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("An Item No Entry References Is Collected At Launch", anItemNoEntryReferencesIsCollectedAtLaunch)
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))

    private func readable(_ manager: TunnelsManager) -> Set<UUID> {
        Set(manager.tunnels.filter { $0.tunnelConfig != nil }.map(\.id))
    }

    /// Whether the Keychain hands back `ref` itself for the item it opens.
    private func referenceIsCanonical(_ ref: Data) -> Bool? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecValuePersistentRef: ref,
            kSecReturnPersistentRef: true
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let handed = result as? Data else { return nil }
        return handed == ref
    }

    // MARK: - Steps

    func anItemNoEntryReferencesIsCollectedAtLaunch() async {
        let first: TunnelsManager
        do {
            first = try await TunnelsManager.create()
        } catch {
            skip("environment: the system did not list its tunnel entries (\(error))")
            return
        }
        let readableBefore = readable(first)
        log("the system lists \(first.tunnels.count) entries, \(readableBefore.count) of them reading their configuration")

        guard let own = TestConfigFactory.throwaway(name: "Test-Load-\(runTag)") else {
            fail("the config factory produced no throwaway")
            return
        }
        let ownRow: TunnelContainer
        do {
            ownRow = try await first.add(config: own)
        } catch {
            fail("the system refused the step's Test- entry (\(error))")
            return
        }
        onTeardown("remove the step's Test- entry") { try? await first.remove(tunnel: ownRow) }
        if let ref = (ownRow.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.keychainReference {
            log("the step entry's stored reference is \(ref.count) bytes; the Keychain hands back the same bytes for it: "
                + "\(referenceIsCanonical(ref).map { $0 ? "yes" : "no" } ?? "item not found")")
        }

        guard let orphan = Keychain.makeReference(containing: "TE orphan \(runTag)", called: "TE-Load-Orphan-\(runTag)") else {
            fail("makeReference refused the orphan item")
            return
        }
        onTeardown("delete the step's Keychain item") { Keychain.deleteReference(called: orphan) }
        guard check(Keychain.openReference(called: orphan) != nil,
                    "an item that no entry references is sealed and opens") else { return }

        let second: TunnelsManager
        do {
            second = try await TunnelsManager.create()
        } catch {
            fail("the second launch path did not list the tunnel entries (\(error))")
            return
        }
        check(Keychain.openReference(called: orphan) == nil,
              "after the launch path ran, the item no entry references opens nothing")
        let ownListed = second.tunnels.first { $0.id == own.id }
        check(ownListed?.tunnelConfig == own,
              "the step's own entry is listed and still reads its configuration"
              + " (listed=\(ownListed != nil), reads=\(ownListed?.tunnelConfig != nil))")
        let readableAfter = readable(second)
        check(readableAfter == readableBefore.union([own.id]),
              "the entries that read their configuration before still read it"
              + " (before=\(readableBefore.count), after=\(readableAfter.count) with the step's own)")
    }
}
#endif
