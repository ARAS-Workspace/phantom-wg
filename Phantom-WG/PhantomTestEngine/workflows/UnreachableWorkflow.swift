// Unreachable Endpoint
//
// The deterministic negative on the real extension. A `Test-` tunnel whose
// endpoint lives in TEST-NET-1 answers nobody, so the outcome is known in
// advance: the adapter comes up locally and the row shows active while no
// handshake can exist. Mac's Unreachable is the source; its vault step has
// no iOS counterpart. It runs behind the live gate.
//
// Three things must hold in that state: the stats tell the truth rather
// than the status, the user's stop lands, and nothing stays armed or
// stored behind.
//
// Scenarios:
//
//   A — Add Through The Production Path (Blackhole Endpoint)
//       `TunnelsManager.add` lists the tunnel, and it reads its
//       configuration back from the app group Keychain.
//
//   B — Activation Attempt Observed
//       The row leaves rest within 10 s; whether it reaches active is
//       logged.
//
//   C — Green But Dead: Stats Stay Truthful
//       With the row active, the stats carry no handshake.
//
//   D — User Abort Contract
//       A stop brings the row to rest within 15 s.
//
//   E — Truth After Abort
//       A second later the row still rests, the stop was not filed as a
//       failed activation, and no tunnel in the list is armed (a ladder that
//       ran out leaves this row armed by design; it is written down and
//       said).
//
//   F — Cleanup Proof
//       `remove` takes the row out of the list and its Keychain item opens
//       nothing; `Test-Ghost` and `Test-WireGuard` are still listed and read
//       their configuration.

#if DEBUG
import Foundation
import NetworkExtension

final class UnreachableWorkflow: TestWorkflow {
    override var displayName: String { "PhantomTunnel (Unreachable)" }
    override var requiresLiveTunnels: Bool { true }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Add Through The Production Path (Blackhole Endpoint)", addThroughTheProductionPath),
            WorkflowStep("Activation Attempt Observed", activationAttemptObserved),
            WorkflowStep("Green But Dead: Stats Stay Truthful", greenButDead),
            WorkflowStep("User Abort Contract", userAbortContract),
            WorkflowStep("Truth After Abort", truthAfterAbort),
            WorkflowStep("Cleanup Proof", cleanupProof)
        ]
    }

    private var planted: TunnelConfig?
    private var row: TunnelContainer?
    private var item: Data?
    private var reachedActive = false
    private var abortIssued = false
    private var failureBeforeAbort = false

    private func armed() -> [TunnelContainer] {
        tunnels.tunnels.filter { $0.tunnelProvider.isOnDemandEnabled }
    }

    private func describe(_ error: TunnelActivationError?) -> String {
        error.map { String(describing: $0) } ?? "nil"
    }

    // MARK: - Steps

    func addThroughTheProductionPath() async {
        guard let config = TestConfigFactory.throwaway(name: "Test-Unreachable-\(UUID().uuidString.prefix(8))") else {
            fail("the config factory produced no throwaway")
            return
        }
        planted = config
        do {
            row = try await tunnels.add(config: config)
        } catch {
            fail("add was refused (\(error.localizedDescription))")
            return
        }
        onTeardown("remove the planted unreachable tunnel") { [weak self] in
            guard let self, let row = self.tunnels.tunnels.first(where: { $0.id == config.id }) else { return }
            if row.status != .inactive {
                self.tunnels.startDeactivation(of: row)
                _ = await self.awaitStatus(row, is: .inactive, within: 15)
            }
            do {
                try await self.tunnels.remove(tunnel: row)
                self.log("teardown: the planted tunnel was removed")
            } catch {
                self.log("teardown: removing the planted tunnel was refused (\(error.localizedDescription))", .error)
            }
        }
        item = (row?.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.keychainReference
        check(tunnel(named: config.name) != nil && row?.tunnelConfig == config,
              "the tunnel is listed and reads its configuration back from the app group Keychain (\(config.name))")
    }

    func activationAttemptObserved() async {
        guard let row else {
            skip("no planted tunnel")
            return
        }
        tunnels.startActivation(of: row)
        let left = await settle(within: 10) { row.status != .inactive }
        check(left, "the row leaves rest (status=\(row.status))")
        if await awaitStatus(row, is: .active, within: 15) {
            reachedActive = true
            log("the adapter is up on a blackhole endpoint: the green-but-dead window is open", .ok)
        } else {
            log("the row did not reach active (status=\(row.status))", .warn)
        }
    }

    func greenButDead() async {
        guard let row else {
            skip("no planted tunnel")
            return
        }
        guard reachedActive else {
            skip("the session did not reach active")
            return
        }
        switch await providerMessage(row, [0]) {
        case .data(let data):
            let reading = TunnelRuntimeStats.decoded(from: data)
            check(reading?.lastHandshakeTimestamp == 0,
                  "the stats stay truthful: the row is active and no handshake is carried"
                  + " (handshake=\(reading?.lastHandshakeTimestamp ?? -1), tx=\(reading?.txBytes ?? -1))")
        case .empty:
            fail("the stats were answered with no data")
        case .unanswered:
            fail("the stats were unanswered while the row was active")
        }
    }

    func userAbortContract() async {
        guard let row else {
            skip("no planted tunnel")
            return
        }
        if case .failedWhileActivating = row.lastActivationError { failureBeforeAbort = true }
        if row.status == .inactive {
            skip("the row was already at rest before a stop could be issued (error=\(describe(row.lastActivationError)))")
            return
        }
        tunnels.startDeactivation(of: row)
        abortIssued = true
        check(await awaitStatus(row, is: .inactive, within: 15), "the stop brings the row to rest (status=\(row.status))")
    }

    func truthAfterAbort() async {
        guard let row else {
            skip("no planted tunnel")
            return
        }
        try? await Task.sleep(for: .seconds(1))
        check(row.status == .inactive, "a second later the row still rests (status=\(row.status))")
        if abortIssued {
            var failedNow = false
            if case .failedWhileActivating = row.lastActivationError { failedNow = true }
            check(!(failedNow && !failureBeforeAbort),
                  "the stop was not filed as a failed activation (error=\(describe(row.lastActivationError)))")
        }
        var now = armed()
        if now.count == 1, now[0] === row, case .retryLimitReached = row.lastActivationError {
            log("the ladder ran out and left this row armed by design; writing its rule down", .warn)
            row.tunnelProvider.isOnDemandEnabled = false
            try? await row.tunnelProvider.savePreferences()
            now = armed()
        }
        check(now.isEmpty, "no tunnel in the list is armed (armed=\(now.count))")
    }

    func cleanupProof() async {
        guard let row, let planted else {
            skip("nothing to clean")
            return
        }
        do {
            try await tunnels.remove(tunnel: row)
        } catch {
            fail("remove was refused (\(error.localizedDescription))")
            return
        }
        check(tunnel(named: planted.name) == nil, "the tunnel is out of the list")
        if let item {
            check(Keychain.openReference(called: item) == nil, "and its Keychain item opens nothing")
        } else {
            fail("the planted tunnel carried no Keychain reference to check")
        }
        for name in [TestContext.ghostName, TestContext.wireGuardName] {
            check(tunnel(named: name)?.tunnelConfig != nil, "\(name) is still listed and reads its configuration")
        }
    }
}
#endif
