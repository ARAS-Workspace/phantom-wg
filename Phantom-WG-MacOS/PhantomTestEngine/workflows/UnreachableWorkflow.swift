#if DEBUG
import Foundation

/// The deterministic negative: a factory config whose endpoint lives
/// in TEST-NET-1 answers nobody, ever. Unlike the real door configs,
/// the outcome here is guaranteed, which turns the scariest user state
/// into a provable claim: the adapter comes up locally (status shows
/// active) while no handshake can exist — and the stats surface must
/// tell that truth, the user's abort must always land, and nothing may
/// stay armed or stored behind.
///
/// Drives the FULL user import path (`tunnels.add`: name gate → vault
/// store → system entry) and removes everything on the way out;
/// `AllowedIPs` stays inside TEST-NET, so no real traffic is captured
/// while the throwaway tunnel is up.
final class UnreachableWorkflow: TestWorkflow {
    override var displayName: String { "Test PhantomTunnel (Unreachable)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Vault Respawn Window Measured", vaultRespawnWindow),
            WorkflowStep("Import Via Full Path (Blackhole Endpoint)", importViaFullPath),
            WorkflowStep("Activation Attempt Observed", activationAttemptObserved),
            WorkflowStep("Green But Dead: Stats Stay Truthful", greenButDead),
            WorkflowStep("User Abort Contract", userAbortContract),
            WorkflowStep("Truth After Abort", truthAfterAbort),
            WorkflowStep("Cleanup Proof", cleanupProof),
        ]
    }

    private var fakeConfig: TunnelConfig?
    private var fake: TunnelContainer?
    private var reachedActive = false
    /// Whether the abort step actually issued a stop, and what error
    /// the row carried just before it — the truth step compares
    /// against this, so the claim is about what the ABORT changed, not
    /// about whatever an earlier drop may have legitimately recorded.
    private var abortIssued = false
    private var failureRecordedBeforeAbort = false

    // MARK: - Steps

    /// Measures how long custody stays dark after the previous
    /// workflow's deactivation. The tunnel extension hosts the vault
    /// listener and exits with the tunnel (stopTunnel's `exit(0)`), so
    /// a mutation right after a deactivation faces a respawn window
    /// longer than the store retry can bridge — three live runs hit it.
    /// This step documents the real curve on every report and lets the
    /// rest of this workflow run on a vault that answers.
    private func vaultRespawnWindow() async {
        let start = Date()
        while Date().timeIntervalSince(start) < 30 {
            if Task.isCancelled { return }
            if case .ready(let payloads, _) = await vault.ping() {
                log("vault answered at t=\(String(format: "%.1fs", Date().timeIntervalSince(start))) — payloads=\(payloads)", .ok)
                return
            }
            log("vault dark at t=\(String(format: "%.1fs", Date().timeIntervalSince(start)))", .warn)
            try? await Task.sleep(for: .seconds(1))
        }
        fail("vault still dark after 30s — respawn window exceeded the budget")
    }

    private func importViaFullPath() async {
        let name = "TE-Unreachable-\(UUID().uuidString.prefix(8))"
        guard let cfg = TestConfigFactory.throwaway(name: name) else {
            fail("factory produced no config")
            return
        }
        fakeConfig = cfg
        do {
            fake = try await tunnels.add(config: cfg)
        } catch {
            fail("add threw: \(error.localizedDescription)")
            return
        }
        // `cleanupProof` owns the removal and earns its verdict from
        // it. This is the net for the runs that never reach that step:
        // the activation steps below carry their own cancel-returns,
        // and this tunnel is activated, so a Stop can strand it live
        // with an armed recovery rule.
        onTeardown("planted unreachable tunnel") { [weak self] in
            guard let self else { return }
            await self.sweepPlantedTunnel(id: cfg.id, name: name)
        }
        check(tunnel(named: cfg.name) != nil, "tunnel materialized in the list — \(cfg.name)")
        if case .config = await vault.read(id: cfg.id) {
            log("vault holds the payload", .ok)
        } else {
            fail("vault does not answer for the imported id")
        }
    }

    private func activationAttemptObserved() async {
        guard let t = fake else {
            skip("no fake tunnel")
            return
        }
        tunnels.startActivation(of: t)
        let start = Date()
        var leftInactive = false
        // Observer-only, like awaitStatus: read what the manager
        // publishes, never refresh over it.
        while Date().timeIntervalSince(start) < 10 {
            if Task.isCancelled { return }
            if t.status != .inactive {
                leftInactive = true
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        check(leftInactive, "attempt observed — status=\(t.status) at t=\(String(format: "%.1fs", Date().timeIntervalSince(start)))")
        if await awaitStatus(t, is: .active, within: 15) {
            reachedActive = true
            log("adapter up on a blackhole endpoint — the green-but-dead window is open", .ok)
        } else {
            log("did not reach active — status=\(t.status)", .warn)
        }
    }

    private func greenButDead() async {
        guard let t = fake else {
            skip("no fake tunnel")
            return
        }
        guard reachedActive else {
            skip("session did not reach active")
            return
        }
        switch await providerMessage(t, [0]) {
        case .data(let d):
            let stats = StatsFormatter.parse(String(data: d, encoding: .utf8) ?? "")
            check(stats.lastHandshakeTimestamp == 0,
                  "stats stay truthful — status=active yet last_handshake_time_sec=\(stats.lastHandshakeTimestamp) (tx=\(stats.txBytes))")
        case .empty:
            fail("stats answered empty")
        case .unanswered:
            fail("stats unanswered while active")
        }
    }

    private func userAbortContract() async {
        guard let t = fake else {
            skip("no fake tunnel")
            return
        }
        if case .failedWhileActivating = t.lastActivationError {
            failureRecordedBeforeAbort = true
        }
        if t.status == .inactive {
            // No abort can be issued against a tunnel that is already
            // down, and passing on an instant status check would
            // credit this step with a stop it never sent. Which path
            // grounded it is not claimed — the recorded error is
            // reported as-is for the reader.
            skip("tunnel already inactive before an abort could be issued — lastActivationError=\(t.lastActivationError.map { String(describing: $0) } ?? "nil")")
            return
        }
        tunnels.startDeactivation(of: t)
        abortIssued = true
        check(await awaitStatus(t, is: .inactive, within: 15),
              "abort landed — a config that can never connect cannot hold the user")
    }

    private func truthAfterAbort() async {
        guard let t = fake else {
            skip("no fake tunnel")
            return
        }
        try? await Task.sleep(for: .seconds(1))
        check(t.status == .inactive, "status stable inactive (1s later)")
        if abortIssued {
            // The one lie this step exists to rule out: the machinery
            // reading the user's own stop as a session failure. A
            // failure recorded BEFORE the abort is legitimate history
            // and stays out of the claim; one appearing after it is
            // the belt misfiling the stop.
            var failureNow = false
            if case .failedWhileActivating = t.lastActivationError { failureNow = true }
            check(!(failureNow && !failureRecordedBeforeAbort),
                  "the abort was not misfiled as a session failure — lastActivationError=\(t.lastActivationError.map { String(describing: $0) } ?? "nil")")
        } else {
            log("lastActivationError=\(t.lastActivationError.map { String(describing: $0) } ?? "nil")")
        }

        var armed = tunnels.tunnels.filter(\.isActivateOnDemandEnabled)
        if !armed.isEmpty, armed.count == 1, armed[0] === t,
           case .retryLimitReached = t.lastActivationError {
            // The retry-ladder give-up leaves recovery armed BY DESIGN
            // (a timeout is transient). The user-facing promise is that
            // the sweep stands it down.
            log("recovery armed after retry give-up — armed by design; sweeping", .warn)
            await tunnels.disarmAllRecovery()
            armed = tunnels.tunnels.filter(\.isActivateOnDemandEnabled)
        }
        check(armed.isEmpty, "armed-count=\(armed.count) after the abort path")
    }

    private func cleanupProof() async {
        guard let t = fake, let cfg = fakeConfig else {
            skip("nothing to clean")
            return
        }
        do {
            try await tunnels.remove(tunnel: t)
        } catch {
            fail("remove threw: \(error.localizedDescription)")
            return
        }
        if case .missing = await vault.read(id: cfg.id) {
            log("vault payload gone", .ok)
        } else {
            fail("vault still answers for the removed id")
        }
        check(tunnel(named: cfg.name) == nil, "tunnel gone from the list")
        // "Intact" has to mean the payload answers, not just that a
        // row is drawn: the custody contract keeps a row listed even
        // when its bytes no longer decode, so a row-only check would
        // pass over exactly the damage it claims to rule out. The
        // vault-integrity twin was hardened this way already; this is
        // the same sentence with the same evidence behind it.
        for name in [TestContext.ghostName, TestContext.wireGuardName] {
            guard let door = tunnel(named: name) else {
                fail("door config missing after the run — \(name)")
                continue
            }
            // Each answer is its own fact — the old else-collapse
            // printed "no longer decodes" for a vault that simply did
            // not answer, inventing a diagnosis out of silence.
            switch await vault.read(id: door.id) {
            case .config:
                check(true, "\(name): row listed and payload decodes")
            case .undecodable:
                fail("\(name): row is listed but its payload no longer decodes")
            case .missing:
                fail("\(name): row is listed but its payload is gone from the vault")
            case .unreachable:
                skip("environment: vault unreachable — \(name) intactness unproven")
            }
        }
    }
}
#endif
