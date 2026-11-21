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
//       configuration. An item that no entry references is sealed through
//       `Keychain.makeReference` (a throwaway value, no secret), and a
//       `Test-` entry of the step's own is added through the first
//       manager, so the system holds one entry this step answers for.
//       That the item is sealed and opens, and that the entry is added
//       and reads its configuration, are the step's first two claims: a
//       refusal of either is the red of its claim, and the step ends
//       there. Then a second `create()` runs. The claims after it are
//       that the item opens nothing, that the step's own entry still
//       reads its configuration, and that the entries read before still
//       read it.
//       How many of the listed entries' stored references equal the form
//       the Keychain hands back for them, and whether the step entry's
//       does, is logged. The item and the `Test-` entry are deleted on the
//       way out.

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

    /// The step's own `Test-` entry, added through `manager`: the claim
    /// that it is added and reads its configuration, its removal on the
    /// way out, and the log line on its stored reference. `nil` once the
    /// factory or the claim failed.
    private func ownEntry(addedThrough manager: TunnelsManager) async -> TunnelConfig? {
        guard let own = TestConfigFactory.throwaway(name: "Test-Load-\(runTag)") else {
            fail("the config factory produced no throwaway")
            return nil
        }
        let added = "the step's own entry is added and reads its configuration"
        let row: TunnelContainer
        do {
            row = try await manager.add(config: own)
        } catch {
            check(false, added + " (refused: \(error))")
            return nil
        }
        onTeardown("remove the step's Test- entry") { try? await manager.remove(tunnel: row) }
        guard check(row.tunnelConfig == own, added + " (reads=\(row.tunnelConfig != nil))") else { return nil }
        if let ref = (row.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.keychainReference {
            log("the step entry's stored reference is \(ref.count) bytes; the Keychain hands back the same bytes for it: "
                + "\(referenceIsCanonical(ref).map { $0 ? "yes" : "no" } ?? "item not found")")
        }
        return own
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
        let stored = first.tunnels.compactMap {
            ($0.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.keychainReference
        }
        log("of their \(stored.count) stored references the Keychain hands back the same bytes for"
            + " \(stored.filter { referenceIsCanonical($0) == true }.count)")

        let sealed = "an item that no entry references is sealed and opens"
        guard let orphan = Keychain.makeReference(containing: "TE orphan \(runTag)", called: "TE-Load-Orphan-\(runTag)") else {
            check(false, sealed + " (makeReference refused the item)")
            return
        }
        onTeardown("delete the step's Keychain item") { Keychain.deleteReference(called: orphan) }
        guard check(Keychain.openReference(called: orphan) != nil, sealed) else { return }
        guard let own = await ownEntry(addedThrough: first) else { return }

        let second: TunnelsManager
        do {
            second = try await TunnelsManager.create()
        } catch {
            fail("the second launch path did not list the tunnel entries (\(error))")
            return
        }
        check(Keychain.openReference(called: orphan) == nil,
              "after the launch path ran, the item no entry references opens nothing")
        // A row whose configuration does not open carries an id of its own:
        // once the entry's id finds no row, the entry is looked up by its name.
        let ownListed = second.tunnels.first { $0.id == own.id } ?? second.tunnels.first { $0.name == own.name }
        check(ownListed?.tunnelConfig == own,
              "the step's own entry is listed and still reads its configuration"
              + " (listed=\(ownListed != nil), reads=\(ownListed?.tunnelConfig != nil))")
        let readableAfter = readable(second)
        check(readableBefore.isSubset(of: readableAfter),
              "the entries that read their configuration before still read it"
              + " (before=\(readableBefore.count), of them after=\(readableBefore.intersection(readableAfter).count))")
    }
}
#endif
