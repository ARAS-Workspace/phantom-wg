#if DEBUG
import Foundation

/// Two config-shape contracts that only bite when a hostile or damaged
/// payload reaches the tunnel layer. Both are expected to expose a real
/// gap on the first run — they are written as the specification the
/// product must meet, and the failing step is the finding.
///
/// 1. Empty AllowedIPs: a peer that routes nothing must be refused. If
///    such a config reaches `.active`, WireGuard has no cryptokey
///    route and every packet leaves the utun in the clear — a total
///    leak behind a green status. The check is a real activation of a
///    config the typed model permits but no user should run.
/// 2. Multi-[Peer] import: a `.conf` with two `[Peer]` sections must
///    not silently collapse into one damaged peer. Either the parser
///    preserves both, or it rejects the input — a quiet merge is the
///    failure.
final class ConfigContractWorkflow: TestWorkflow {
    override var displayName: String { "Config Contract (Leak + Parse Guards)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Empty AllowedIPs Refused (No-Route Leak Guard)", emptyAllowedIPs),
            WorkflowStep("Multi-Peer Conf Not Silently Collapsed", multiPeer),
        ]
    }

    private var planted: TunnelContainer?
    private var plantedId: UUID?

    // MARK: - Steps

    private func emptyAllowedIPs() async {
        let name = "TE-NoRoute-\(UUID().uuidString.prefix(8))"
        guard let cfg = TestConfigFactory.emptyAllowedIPs(name: name) else {
            fail("factory produced no config")
            return
        }
        plantedId = cfg.id
        do {
            planted = try await tunnels.add(config: cfg)
        } catch {
            // Refusing at import is one valid way to honour the guard.
            log("import refused a no-route config: \(error.localizedDescription)", .ok)
            check(true, "no-route config never became a runnable tunnel")
            return
        }
        guard let t = planted else {
            fail("added but no container")
            return
        }
        tunnels.startActivation(of: t)
        // The safe outcome is that it never reaches active. If it does,
        // that is the leak: a live tunnel with no cryptokey route.
        let wentActive = await awaitStatus(t, is: .active, within: 12)
        check(!wentActive,
              wentActive
                ? "LEAK: no-route config reached .active — traffic would leave in the clear"
                : "no-route config was kept from going active (status=\(t.status))")
        if t.status != .inactive {
            tunnels.startDeactivation(of: t)
            _ = await awaitStatus(t, is: .inactive, within: 15)
        }
        // Clean the planted tunnel whatever the verdict — remove()
        // carries the respawn-window retry, so it survives the exit(0).
        try? await tunnels.remove(tunnel: t)
        check(tunnel(named: name) == nil, "planted no-route tunnel removed")
    }

    private func multiPeer() async {
        let text = TestConfigFactory.multiPeerConfText()
        do {
            let draft = try ConfParser.parse(text)
            // Parser accepted it — the only acceptable acceptance keeps
            // BOTH peers. The current section model merges same-named
            // sections, so a single collapsed peer is the finding.
            let result = draft.validate()
            if let cfg = result.config {
                check(cfg.wireguard.peer.allowedIPs.count >= 4,
                      "both peers preserved — allowedIPs entries=\(cfg.wireguard.peer.allowedIPs.count) (2 peers x 2 ranges expected)")
            } else {
                // Rejected at validation is also acceptable (explicit refusal).
                check(true, "multi-peer config rejected at validation (explicit) — errors=\(result.errors.count)")
            }
        } catch {
            check(true, "multi-peer config rejected at parse (explicit) — \(error)")
        }
    }
}
#endif
