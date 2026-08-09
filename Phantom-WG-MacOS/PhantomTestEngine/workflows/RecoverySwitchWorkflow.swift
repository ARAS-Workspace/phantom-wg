#if DEBUG
import Foundation

/// Proves the armed<=1 invariant HOLDS THROUGH a live switch, not just
/// at rest. Activating a second tunnel disarms every other tunnel's
/// recovery rule first (TunnelsManager+Activation), so at no observed
/// instant may two tunnels carry an armed on-demand rule.
///
/// Both door configs are real, so this needs a reachable endpoint for
/// the tunnels to actually reach `.active`; when they cannot, the
/// switch still runs and the invariant is still sampled — the claim is
/// about arming, not about connectivity.
///
/// Note the deliberate boundary: the disarm-others save is
/// fire-and-forget (`savePreferences { _ in }`), so a failed save on a
/// contended system could in principle leave a stale armed rule. That
/// failure cannot be injected from in-app, so this workflow proves the
/// happy path densely and leaves the save-failure branch to a future
/// mock-capable layer.
final class RecoverySwitchWorkflow: TestWorkflow {
    override var displayName: String { "Recovery Switch (Armed<=1 Through A Live Handover)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Ground Both Tunnels", groundBoth),
            WorkflowStep("Arm First (Standalone)", armFirst),
            WorkflowStep("Switch To Second (Ghost) — Invariant Sampled Throughout", switchSampled),
            WorkflowStep("Ground + Final Sweep", groundAndSweep),
        ]
    }

    private var first: TunnelContainer? { tunnel(named: TestContext.wireGuardName) }
    private var second: TunnelContainer? { tunnel(named: TestContext.ghostName) }
    private var firstArmed = false

    // MARK: - Steps

    private func groundBoth() async {
        for t in [first, second].compactMap({ $0 }) where t.status != .inactive {
            tunnels.startDeactivation(of: t)
            _ = await awaitStatus(t, is: .inactive, within: 20)
        }
        await tunnels.disarmAllRecovery()
        let armed = tunnels.tunnels.filter(\.isActivateOnDemandEnabled)
        check(armed.isEmpty, "clean slate — armed-count=\(armed.count)")
    }

    private func armFirst() async {
        guard let t = first else {
            fail("standalone door config not found")
            return
        }
        tunnels.startActivation(of: t)
        guard await awaitStatus(t, is: .active, within: 30) else {
            fail("standalone did not reach active — lastActivationError=\(t.lastActivationError.map { String(describing: $0) } ?? "nil")")
            return
        }
        firstArmed = true
        let armed = tunnels.tunnels.filter(\.isActivateOnDemandEnabled)
        check(armed.count == 1 && armed.first === t, "armed on standalone only — armed-count=\(armed.count)")
    }

    /// Fire the second activation and, IN PARALLEL, sample the armed
    /// count every 100ms across the whole handover. The peak must never
    /// exceed one. Sampling the observed `isActivateOnDemandEnabled` is
    /// exactly the user-facing truth (what the OS would revive).
    private func switchSampled() async {
        guard firstArmed, let a = first, let b = second else {
            skip("first tunnel not armed")
            return
        }
        var peak = 0
        var samples = 0
        let sampler = Task { @MainActor in
            let start = Date()
            while Date().timeIntervalSince(start) < 35 {
                if Task.isCancelled { break }
                let n = tunnels.tunnels.filter(\.isActivateOnDemandEnabled).count
                peak = max(peak, n)
                samples += 1
                if b.status == .active { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        tunnels.startActivation(of: b)
        let reached = await awaitStatus(b, is: .active, within: 35)
        sampler.cancel()
        _ = await sampler.value

        check(peak <= 1, "armed-count never exceeded 1 during the switch — peak=\(peak) over \(samples) samples")
        if reached {
            let armed = tunnels.tunnels.filter(\.isActivateOnDemandEnabled)
            check(armed.count == 1 && armed.first === b, "recovery moved to the second tunnel — armed=\(armed.count)")
            check(!a.isActivateOnDemandEnabled, "first tunnel disarmed by the handover")
        } else {
            skip("environment: second tunnel did not reach active, invariant still sampled (peak=\(peak))")
        }
    }

    private func groundAndSweep() async {
        for t in [first, second].compactMap({ $0 }) where t.status != .inactive {
            tunnels.startDeactivation(of: t)
            _ = await awaitStatus(t, is: .inactive, within: 20)
        }
        await tunnels.disarmAllRecovery()
        let armed = tunnels.tunnels.filter(\.isActivateOnDemandEnabled)
        check(armed.isEmpty, "final sweep — armed-count=\(armed.count)")
    }
}
#endif
