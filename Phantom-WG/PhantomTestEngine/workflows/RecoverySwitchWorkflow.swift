// Recovery Switch
//
// The "at most one armed rule" invariant held THROUGH a live switch on the
// real Network Extension, not only at rest. Mac's RecoverySwitch is the
// source.
//
// The family runs behind the live gate (`requiresLiveTunnels`):
// `Test-WireGuard` and `Test-Ghost` listed, both on the real extension.
// Otherwise every step is skipped with the gate's reading, and on a
// simulator the gate stays shut.
//
// Scenarios:
//
//   A — Ground Both Tunnels
//       The two test tunnels are brought to rest and their rule written
//       down: both rest and neither is armed. Other armed tunnels in the
//       list are logged; the first activation's sweep answers for them.
//
//   B — Arm First (Standalone)
//       `Test-WireGuard` reaches active within the activation ladder's
//       length, and it is the one armed tunnel in the list.
//
//   C — Switch To Second (Ghost), Invariant Sampled Throughout
//       A press on `Test-Ghost` queues it and stops `Test-WireGuard`; the
//       armed count across the list is sampled every 100 ms until
//       `Test-Ghost` is active. The peak never exceeds one, recovery moves
//       to `Test-Ghost`, and `Test-WireGuard` is disarmed.
//
//   D — Ground And Final Sweep
//       Both test tunnels rest, and no tunnel in the list is armed.
//
// "Armed" reads each listed provider's `isOnDemandEnabled`: this process's
// last-written flag, which is the right reading for how many tunnels the
// APP has armed at once, and not a reading of the rule the system acts on.
//
// Residue: the user's two test tunnels, activated and armed by the steps.
// The teardown brings both to rest and writes their rule down.

#if DEBUG
import Foundation

final class RecoverySwitchWorkflow: TestWorkflow {
    override var displayName: String { "Recovery Switch (At Most One Armed Rule Through A Live Switch)" }
    override var requiresLiveTunnels: Bool { true }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Ground Both Tunnels", groundBothTunnels),
            WorkflowStep("Arm First (Standalone)", armFirst),
            WorkflowStep("Switch To Second (Ghost), Invariant Sampled Throughout", switchToSecond),
            WorkflowStep("Ground And Final Sweep", groundAndFinalSweep)
        ]
    }

    private var firstArmed = false

    private var first: TunnelContainer? { tunnel(named: TestContext.wireGuardName) }
    private var second: TunnelContainer? { tunnel(named: TestContext.ghostName) }
    private var testTunnels: [TunnelContainer] { [first, second].compactMap { $0 } }

    /// The activation ladder's whole length and a margin.
    private var activationBudget: Double { Double(tunnels.maxRetries) * tunnels.retryInterval + 5 }

    private func armed() -> [TunnelContainer] {
        tunnels.tunnels.filter { $0.tunnelProvider.isOnDemandEnabled }
    }

    private func describe(_ rows: [TunnelContainer]) -> String {
        rows.map { "\($0.name)=\($0.status)" }.joined(separator: ", ")
    }

    /// Brings the test tunnels to rest, then writes down the rule of any of
    /// them still armed: a ladder that ran out leaves a resting row armed.
    private func ground() async -> [String] {
        var notes: [String] = []
        for row in testTunnels where row.status != .inactive {
            tunnels.startDeactivation(of: row)
            let rested = await awaitStatus(row, is: .inactive, within: 20)
            notes.append("\(row.name) rested=\(rested)")
        }
        for row in testTunnels where row.tunnelProvider.isOnDemandEnabled {
            row.tunnelProvider.isOnDemandEnabled = false
            do {
                try await row.tunnelProvider.savePreferences()
                notes.append("\(row.name) rule written down")
            } catch {
                notes.append("\(row.name) rule write refused (\(error.localizedDescription))")
            }
        }
        return notes
    }

    // MARK: - Steps

    func groundBothTunnels() async {
        onTeardown("bring the test tunnels to rest") { [weak self] in
            guard let self else { return }
            let notes = await self.ground()
            self.log("teardown: " + (notes.isEmpty ? "both test tunnels already rest, neither armed" : notes.joined(separator: "; ")))
        }
        let notes = await ground()
        if !notes.isEmpty { log(notes.joined(separator: "; ")) }
        check(testTunnels.allSatisfy { $0.status == .inactive && !$0.tunnelProvider.isOnDemandEnabled },
              "both test tunnels rest and neither is armed (\(describe(testTunnels)))")
        let others = armed().filter { row in !testTunnels.contains { $0 === row } }
        if !others.isEmpty {
            log("other armed tunnels in the list: \(others.map(\.name).joined(separator: ", ")); the first activation's sweep answers for them")
        }
    }

    func armFirst() async {
        guard let row = first else {
            fail("\(TestContext.wireGuardName) is not listed")
            return
        }
        tunnels.startActivation(of: row)
        guard await awaitStatus(row, is: .active, within: activationBudget) else {
            fail("\(row.name) did not reach active within \(Int(activationBudget))s"
                 + " (error=\(row.lastActivationError.map { String(describing: $0) } ?? "nil"))")
            return
        }
        firstArmed = true
        let now = armed()
        check(now.count == 1 && now.first === row,
              "\(row.name) is the one armed tunnel in the list (armed=\(now.count): \(now.map(\.name).joined(separator: ", ")))")
    }

    @MainActor
    private final class Sampler {
        var peak = 0
        var samples = 0
    }

    func switchToSecond() async {
        guard firstArmed, let rowA = first, let rowB = second else {
            skip("the first tunnel never came up, so there is no switch to sample")
            return
        }
        let budget = activationBudget
        let sampler = Sampler()
        let sampling = Task { @MainActor in
            let start = Date()
            while Date().timeIntervalSince(start) < budget {
                if Task.isCancelled { break }
                sampler.peak = max(sampler.peak, self.armed().count)
                sampler.samples += 1
                if rowB.status == .active { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        tunnels.startActivation(of: rowB)
        let reached = await awaitStatus(rowB, is: .active, within: budget)
        sampling.cancel()
        _ = await sampling.value

        check(sampler.samples > 0, "the invariant was sampled (\(sampler.samples) samples across the switch)")
        check(sampler.peak <= 1, "the armed count never exceeded one during the switch (peak=\(sampler.peak))")
        guard reached else {
            skip("environment: \(rowB.name) did not reach active within \(Int(budget))s"
                 + " (error=\(rowB.lastActivationError.map { String(describing: $0) } ?? "nil"), peak=\(sampler.peak))")
            return
        }
        let now = armed()
        check(now.count == 1 && now.first === rowB,
              "recovery moved to \(rowB.name) (armed=\(now.count): \(now.map(\.name).joined(separator: ", ")))")
        check(!rowA.tunnelProvider.isOnDemandEnabled && rowA.status == .inactive,
              "\(rowA.name) rests, disarmed by the switch (status=\(rowA.status))")
    }

    func groundAndFinalSweep() async {
        let notes = await ground()
        if !notes.isEmpty { log(notes.joined(separator: "; ")) }
        let now = armed()
        check(testTunnels.allSatisfy { $0.status == .inactive } && now.isEmpty,
              "both test tunnels rest and no tunnel in the list is armed"
              + " (\(describe(testTunnels)); armed=\(now.count))")
    }
}
#endif
