#if DEBUG
import Foundation

/// Proves the harness is wired end to end on the live services: the two
/// test configs are present (the door's fuel), the vault answers as the
/// app identity, and ghost vs standalone is read correctly. No server.
///
/// A model workflow: each `steps` entry names a step method; the method
/// bodies are pure logic using the inherited helpers (log/check/pass/fail
/// and the service shortcuts). No context or reporter is threaded in.
final class SanityWorkflow: TestWorkflow {
    override var displayName: String { "Sanity Check" }
    override var needsServer: Bool { false }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Live Services Connected", liveServices),
            WorkflowStep("Test Configs Present (Door)", testConfigs),
            WorkflowStep("Read Test-Ghost from vault (Ghost Expected)", readGhost),
            WorkflowStep("Read Test-WireGuard from vault (Standalone Expected)", readWireGuard),
        ]
    }

    // MARK: - Steps

    func liveServices() async {
        log("TunnelsManager: \(tunnels.tunnels.count) tunnels visible")
        log("vault / coordinator / daemon-client obtained from @Environment", .ok)
    }

    func testConfigs() async {
        check(tunnel(named: TestContext.ghostName) != nil,
              "\(TestContext.ghostName): \(tunnel(named: TestContext.ghostName) != nil ? "present" : "absent")")
        check(tunnel(named: TestContext.wireGuardName) != nil,
              "\(TestContext.wireGuardName): \(tunnel(named: TestContext.wireGuardName) != nil ? "present" : "absent")")
    }

    func readGhost() async { await read(TestContext.ghostName, expectGhost: true) }
    func readWireGuard() async { await read(TestContext.wireGuardName, expectGhost: false) }

    // MARK: - Shared

    private func read(_ name: String, expectGhost: Bool) async {
        guard let container = tunnel(named: name) else {
            fail("\(name): not found")
            return
        }
        for attempt in 1...3 {
            switch await vault.read(id: container.id) {
            case .config(let cfg):
                check(cfg.isGhostMode == expectGhost,
                      "vault: config read — isGhostMode=\(cfg.isGhostMode) (expected \(expectGhost))")
                return
            case .missing:
                fail("vault: missing")
                return
            case .unreachable:
                log("vault: unreachable (attempt \(attempt)/3)", .warn)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        fail("vault did not answer in 3 attempts")
    }
}
#endif
