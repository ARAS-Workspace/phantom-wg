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
/// Note the boundary: the disarm-others path reads its save's outcome
/// now (`standDownRecovery` — a refused save re-reads the store and
/// the flag carries the store's answer, with a log line naming the
/// tunnel that kept its rule). So a refused disarm IS visible to this
/// sampler as peak=2, and that reading is deliberate honesty, not an
/// app regression. The refusal itself still cannot be injected against
/// the real door configs this workflow drives; the seam DOES drive it
/// — ActivationSeamWorkflow's refused-disarm step, via
/// `FakeSlotProvider.SaveAnswer.fails`.
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
        // This workflow's residue is not a planted config — it is the
        // user's own two door tunnels, activated and armed by the
        // steps below. `groundAndSweep` owns that on the normal path;
        // a Stop between arming and sweeping would otherwise leave a
        // live session with a connect-on-any-network rule behind it.
        onTeardown("door tunnels left armed") { [weak self] in
            guard let self else { return }
            var grounded: [String] = []
            for t in [self.first, self.second].compactMap({ $0 }) where t.status != .inactive {
                self.tunnels.startDeactivation(of: t)
                let ok = await self.awaitStatus(t, is: .inactive, within: 15)
                grounded.append("\(t.name)=\(ok)")
            }
            // Grounding is not disarming, and this workflow's whole
            // subject is the armed rule. A rung that failed its save
            // after `armRecovery` leaves a tunnel `.inactive` AND
            // armed, which the loop above skips entirely — so ask the
            // count, and if anything is still armed run the same sweep
            // the owning step uses.
            var armed = self.tunnels.tunnels.filter(\.isActivateOnDemandEnabled).count
            if armed > 0 {
                await self.tunnels.disarmAllRecovery()
                armed = self.tunnels.tunnels.filter(\.isActivateOnDemandEnabled).count
            }
            if grounded.isEmpty && armed == 0 {
                self.log("teardown: both door tunnels already grounded, armed-count=0")
            } else {
                let detail = grounded.isEmpty ? "none needed grounding" : grounded.joined(separator: " ")
                self.log("teardown: \(detail), armed-count=\(armed) after sweep", armed == 0 ? .warn : .error)
            }
        }
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
        // Same budget as the ladder, for the same reason as the twin
        // in PhantomTunnelWorkflow: a slow-but-correct connect must
        // not print red here either.
        guard await awaitStatus(t, is: .active, within: activationBudget) else {
            fail("standalone did not reach active in \(Int(activationBudget))s — lastActivationError=\(t.lastActivationError.map { String(describing: $0) } ?? "nil")")
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
            // The same ladder budget the wait below uses: a sampler
            // that stops first would let the last seconds of the
            // handover go unwatched while the step still claims the
            // invariant held "throughout".
            while Date().timeIntervalSince(start) < self.activationBudget {
                if Task.isCancelled { break }
                let n = tunnels.tunnels.filter(\.isActivateOnDemandEnabled).count
                peak = max(peak, n)
                samples += 1
                if b.status == .active { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        tunnels.startActivation(of: b)
        let reached = await awaitStatus(b, is: .active, within: activationBudget)
        sampler.cancel()
        _ = await sampler.value

        // An invariant that only ever reads zero has not been tested,
        // it has been missed. The sampler breaks as soon as the second
        // tunnel goes active, so a handover that never armed anything
        // would leave peak=0 and still print a confident "never
        // exceeded 1" — which is exactly what the last two runs did
        // while the ghost tunnel was failing to start. Both bounds are
        // claimed now: the rule was seen ON at some point, and it was
        // never seen on twice.
        check(samples > 0, "the invariant was sampled at all — \(samples) samples across the handover")
        if reached {
            check(peak >= 1, "the rule was observed armed during the switch — peak=\(peak)")
        }
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
