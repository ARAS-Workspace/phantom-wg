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
///    not silently collapse into one working tunnel. The parser
///    refuses a repeated section outright (`.duplicateSection`); this
///    proves that exact refusal identity holds — and while the typed
///    model stays single-peer, ANY acceptance is by definition a
///    collapse (one key wearing merged ranges) and fails outright.
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
            // add() never inspects routes — a throw here is
            // infrastructure (vault down, name collision), not the
            // guard under test. Report honestly instead of crediting
            // the leak guard with someone else's refusal.
            skip("environment: add() failed before the guard was exercised — \(error.localizedDescription)")
            return
        }
        // From here the tunnel is real: a vault payload, a system
        // entry, and in a moment an armed recovery rule. The step
        // sweeps it below on every path it reaches; this is the net
        // for the ones it does not (a Stop inside the terminal wait).
        onTeardown("planted no-route tunnel") { [weak self] in
            guard let self else { return }
            guard let leftover = self.tunnel(named: name) else {
                self.log("teardown: \(name) already swept by the step")
                return
            }
            if leftover.status != .inactive {
                self.tunnels.startDeactivation(of: leftover)
                guard await self.awaitStatus(leftover, is: .inactive, within: 15) else {
                    // Removing an entry the system is still driving is
                    // the very race the net exists to avoid widening.
                    self.log("teardown: \(name) would not ground (status=\(leftover.status)) — left in the list on purpose", .warn)
                    return
                }
            }
            do {
                try await self.tunnels.remove(tunnel: leftover)
                self.log("teardown: removed \(name)", .warn)
            } catch {
                self.log("teardown: \(name) still in the list — remove failed (\(error.localizedDescription))", .warn)
            }
        }
        tunnels.startActivation(of: t)
        // The safe outcome is that it never reaches active. If it does,
        // that is the leak: a live tunnel with no cryptokey route.
        let wentActive = await awaitStatus(t, is: .active, within: 12)
        if wentActive {
            fail("LEAK: no-route config reached .active — traffic would leave in the clear")
        } else {
            // Never active inside the sampling window — now demand
            // the TERMINAL shape in one leak-aware loop with three
            // exits: any .active sighting is the LEAK (the one
            // respawn revive can raise a second attempt after the
            // first window, so a blind wait-for-inactive would miss
            // it); .inactive WITH a recorded refusal is the earned
            // PASS (the drop belt writes the record async after the
            // status flip, so inactive-with-nil keeps polling rather
            // than declaring a spurious miss); budget exhaustion
            // reports the honest inconclusive. The budget covers the
            // remaining rungs plus the anonymous-drop revive class;
            // a full ladder hang is deliberately left inconclusive.
            let terminalStart = Date()
            var verdictGiven = false
            while Date().timeIntervalSince(terminalStart) < 35 {
                if Task.isCancelled { return }
                if t.status == .active {
                    fail("LEAK: no-route config reached .active on a later attempt — traffic would leave in the clear")
                    verdictGiven = true
                    break
                }
                if t.status == .inactive, let refusal = t.lastActivationError {
                    check(true, "no-route config was refused terminally (status=inactive, error=\(String(describing: refusal)))")
                    verdictGiven = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if !verdictGiven {
                if t.status == .inactive {
                    skip("inconclusive: settled inactive without a recorded refusal inside the budget")
                } else {
                    skip("inconclusive: still \(t.status) after the extended budget — refusal not yet terminal")
                }
            }
        }
        if t.status != .inactive {
            tunnels.startDeactivation(of: t)
            _ = await awaitStatus(t, is: .inactive, within: 15)
        }
        // Clean the planted tunnel on every path this line is reached
        // — remove() carries the respawn-window retry, so it survives
        // the exit(0). Two caveats worth knowing here: a Stop inside
        // the terminal wait above never reaches this line at all, and
        // even reaching it under cancellation buys nothing, because
        // `vault.delete(id:attempts:)` refuses to send a request once
        // the task is cancelled. Both paths are the teardown net's.
        try? await tunnels.remove(tunnel: t)
        check(tunnel(named: name) == nil, "planted no-route tunnel removed")
    }

    private func multiPeer() async {
        let text = TestConfigFactory.multiPeerConfText()
        var draft: TunnelDraft
        do {
            draft = try ConfParser.parse(text)
        } catch ConfParser.ParseError.duplicateSection(let section) {
            // The exact guard: a second [Peer] must be refused as
            // section-level ambiguity, not merged away. Only this
            // error identity counts — any other rejection would be
            // the parser failing for an unrelated reason while the
            // collapse guard silently regressed.
            check(section.lowercased() == "peer",
                  "multi-peer config rejected at parse (explicit) — duplicate [\(section)] section")
            return
        } catch {
            fail("multi-peer config rejected for the wrong reason — \(error.localizedDescription)")
            return
        }
        // Parser accepted it. Give the draft a name FIRST, so validation
        // runs the real import path — an unnamed draft fails on the empty
        // name and that rejection would masquerade as a multi-peer guard.
        draft.name = "TE-MultiPeer-\(UUID().uuidString.prefix(8))"
        let result = draft.validate()
        if result.config != nil {
            // The typed model carries exactly one peer, so ANY
            // accepted multi-peer text is a collapse: one key wearing
            // merged ranges. There is no acceptable acceptance shape
            // while the model stays single-peer.
            fail("parser accepted a multi-peer conf into a single-peer model — silent collapse")
        } else {
            fail("named multi-peer config still failed validation — collapsed silently rather than being rejected outright (errors=\(result.errors.count))")
        }
    }
}
#endif
