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
//       configuration. Then an item that no entry references is sealed
//       through `Keychain.makeReference` (a throwaway value, no secret),
//       and a second `create()` runs. The claims are that the item opens
//       nothing afterwards, and that the same listed entries still read
//       their configuration. The item is deleted on the way out.

#if DEBUG
import Foundation

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
        let readableAfter = readable(second)
        check(readableAfter == readableBefore,
              "the listed entries that read their configuration before still read it"
              + " (before=\(readableBefore.count), after=\(readableAfter.count))")
    }
}
#endif
