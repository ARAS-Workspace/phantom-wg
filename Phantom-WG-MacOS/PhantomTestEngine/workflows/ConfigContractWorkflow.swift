#if DEBUG
import Foundation

/// Two config-shape contracts that only bite when a hostile or damaged
/// payload reaches the tunnel layer. Each guards a shipped behaviour and
/// fails only if that behaviour regresses.
///
/// 1. Empty AllowedIPs: a peer that routes nothing must be refused. If
///    such a config reached `.active`, WireGuard would have no cryptokey
///    route and every packet would leave the utun in the clear — a
///    total leak behind a green status. The builder now throws on empty
///    AllowedIPs; this activates a config the typed model permits but
///    no user should run and proves it never goes active.
/// 2. Multi-[Peer] import: a `.conf` with two `[Peer]` sections must
///    not silently collapse into one working tunnel. The parser merges
///    same-named sections, so the merged result must be rejected (or,
///    if ever accepted, preserve both peers) — a quiet merge that then
///    activates is the failure.
final class ConfigContractWorkflow: TestWorkflow {
    override var displayName: String { "Config Contract (Leak + Parse Guards)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Empty AllowedIPs Refused (No-Route Leak Guard)", emptyAllowedIPs),
            WorkflowStep("Multi-Peer Conf Not Silently Collapsed", multiPeer),
        ]
    }

    // MARK: - Steps

    private func emptyAllowedIPs() async {
        let name = "TE-NoRoute-\(UUID().uuidString.prefix(8))"
        guard let cfg = TestConfigFactory.emptyAllowedIPs(name: name) else {
            fail("factory produced no config")
            return
        }
        let t: TunnelContainer
        do {
            t = try await tunnels.add(config: cfg)
        } catch {
            // Refusing at import is one valid way to honour the guard.
            log("import refused a no-route config: \(error.localizedDescription)", .ok)
            check(true, "no-route config never became a runnable tunnel")
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
        var draft: TunnelDraft
        do {
            draft = try ConfParser.parse(text)
        } catch {
            // Explicit rejection at parse is the correct guard — the
            // collapse happens in the section merge, so this is where
            // it must be caught.
            check(true, "multi-peer config rejected at parse (explicit) — \(error.localizedDescription)")
            return
        }
        // Parser accepted it. Give the draft a name FIRST, so validation
        // runs the real import path — an unnamed draft fails on the empty
        // name and that rejection would masquerade as a multi-peer guard.
        // The only acceptable acceptance keeps BOTH peers; a single
        // collapsed peer (one key, both ranges) is the failure.
        draft.name = "TE-MultiPeer-\(UUID().uuidString.prefix(8))"
        let result = draft.validate()
        if let cfg = result.config {
            check(cfg.wireguard.peer.allowedIPs.count >= 4,
                  "both peers preserved — allowedIPs entries=\(cfg.wireguard.peer.allowedIPs.count) (a single collapsed peer would be < 4)")
        } else {
            fail("named multi-peer config still failed validation — collapsed silently rather than being rejected outright (errors=\(result.errors.count))")
        }
    }
}
#endif
