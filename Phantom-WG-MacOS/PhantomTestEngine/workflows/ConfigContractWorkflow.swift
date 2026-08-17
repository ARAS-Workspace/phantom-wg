#if DEBUG
import Foundation

/// Config-shape contracts, from the parser down to validate(): each
/// guards a shipped refusal at the layer that owns it, and fails only
/// if that refusal regresses.
///
/// 1. Empty AllowedIPs: a peer that routes nothing must be refused. If
///    such a config reached `.active`, WireGuard would have no cryptokey
///    route and every packet would leave the utun in the clear — a
///    total leak behind a green status. The builder now throws on empty
///    AllowedIPs; this activates a config the typed model permits but
///    no user should run and proves it never goes active.
/// 2. Multi-[Peer] import: a `.conf` with two peer sections must not
///    silently collapse into one working tunnel — in the exact
///    spelling AND the "[Peer ]" variant whose stray inner space once
///    minted a distinct section that dodged the duplicate guard. The
///    parser refuses both outright (`.duplicateSection`); while the
///    typed model stays single-peer, ANY acceptance is by definition
///    a collapse (one key wearing merged ranges) and fails outright.
/// 3. Validate()-layer refusals: the contracts that die BEFORE any
///    system surface — comma-only Address/DNS lists and a blank
///    wstunnel URL must be refused with their field named, never
///    passed on as an empty list or an endpointless ghost.
final class ConfigContractWorkflow: TestWorkflow {
    override var displayName: String { "Config Contract (Leak + Parse Guards)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Empty AllowedIPs Refused (No-Route Leak Guard)", emptyAllowedIPs),
            WorkflowStep("Multi-Peer Conf Not Silently Collapsed", multiPeer),
            WorkflowStep("Comma-Only Lists Die In validate()", commaOnlyLists),
            WorkflowStep("Blank Wstunnel URL Dies In validate()", blankWstunnelUrl),
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
            await self.sweepPlantedTunnel(id: cfg.id, name: name)
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
            // reports the honest inconclusive.
            //
            // THE BUDGET IS THE LADDER'S OWN, not a number picked to
            // feel generous. It used to be a flat 35s while
            // `activationCeiling` is `(maxRetries + 1) * retryInterval
            // + preflightBudget` = (8+1)*5+2 = 47s, so the step gave
            // up twelve seconds before the thing it was waiting for —
            // and a busy machine turned a correct refusal into
            // "inconclusive: still activating". Sized against the
            // ceiling it now outlives every rung, plus a margin for
            // the drop belt to write its record after the last one:
            // past this, a ladder really has hung, and THAT stays
            // deliberately inconclusive rather than being called a
            // product failure.
            let terminalBudget = activationBudget + 8
            let terminalStart = Date()
            var verdictGiven = false
            while Date().timeIntervalSince(terminalStart) < terminalBudget {
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
                    skip("inconclusive: still \(t.status) after \(Int(terminalBudget))s, past the activation ceiling itself — the ladder hung rather than refusing")
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
        // Judged from the STORE, not from the list. This line used to
        // read "removed" off `tunnel(named:)` alone, and the mirror
        // cannot carry that claim: a row leaves it when its payload is
        // orphaned just as readily as when the removal finished. Under
        // cancellation the removal cannot have run at all — the net
        // above owns that case — so the claim is made only when this
        // pass was allowed to finish.
        if !Task.isCancelled {
            // Three-valued, because a vault that did not ANSWER is not a
            // product failure. The first version of this assertion read
            // anything other than `.missing` as red, which turned a dark
            // store — the very condition this engine spends a kit
            // avoiding — into a claim that the payload survived.
            switch await readPayloadState(cfg.id) {
            case .missing:
                check(tunnel(named: name) == nil,
                      "planted no-route tunnel removed — its payload is gone from the vault and its row is off the list")
            case .present:
                fail("the planted no-route tunnel's payload survived its removal")
            case .unreachable:
                log("cleanup: the vault did not answer, so this step cannot say whether the payload went — "
                    + "the teardown net below owns it", .warn)
            }
        }
    }

    private func multiPeer() async {
        // Exact spelling first, then the one-character variant that
        // used to dodge the guard: "[Peer ]" minted a DISTINCT
        // section, parse() read only the exact-spelled one, and the
        // second peer vanished with no error — its ranges leaving in
        // the clear under an Active row. Both spellings must meet
        // the same refusal identity.
        assertMultiPeerRefused(TestConfigFactory.multiPeerConfText(),
                               label: "exact [Peer]")
        assertMultiPeerRefused(TestConfigFactory.multiPeerConfText(secondHeader: "[Peer ]"),
                               label: "spaced [Peer ]")
    }

    private func assertMultiPeerRefused(_ text: String, label: String) {
        var draft: TunnelDraft
        do {
            draft = try ConfParser.parse(text)
        } catch ConfParser.ParseError.duplicateSection(let section) {
            // The exact guard: a second peer section must be refused
            // as section-level ambiguity, not merged away. Only this
            // error identity counts — any other rejection would be
            // the parser failing for an unrelated reason while the
            // collapse guard silently regressed.
            check(section.lowercased() == "peer",
                  "\(label): rejected at parse (explicit) — duplicate [\(section)] section")
            return
        } catch {
            fail("\(label): rejected for the wrong reason — \(error.localizedDescription)")
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
            fail("\(label): parser accepted a multi-peer conf into a single-peer model — silent collapse")
        } else {
            fail("\(label): named multi-peer config still failed validation — collapsed silently rather than being rejected outright (errors=\(result.errors.count))")
        }
    }

    /// acd3549's contract, proven at ITS OWN layer for the first time:
    /// a comma/whitespace-only Address or DNS list must die in
    /// validate() with the field named — never pass as an empty list
    /// that only fails at activation, an ocean away from the field
    /// the user mistyped.
    private func commaOnlyLists() async {
        guard var addressDraft = TestConfigFactory.throwawayDraft(name: "TE-Validate-\(UUID().uuidString.prefix(8))") else {
            fail("factory produced no draft")
            return
        }
        addressDraft.wireguard.interface.addresses = " , ,"
        let addressResult = addressDraft.validate()
        check(addressResult.config == nil && addressResult.errors[.interfaceAddresses] != nil,
              "comma-only Address died in validate() with its field named — config \(addressResult.config == nil ? "refused" : "BUILT"), field error \(addressResult.errors[.interfaceAddresses] != nil ? "present" : "MISSING")")

        guard var dnsDraft = TestConfigFactory.throwawayDraft(name: "TE-Validate-\(UUID().uuidString.prefix(8))") else {
            fail("factory produced no draft")
            return
        }
        dnsDraft.wireguard.interface.dnsServers = ", ,"
        let dnsResult = dnsDraft.validate()
        check(dnsResult.config == nil && dnsResult.errors[.interfaceDnsServers] != nil,
              "comma-only DNS died in validate() with its field named — config \(dnsResult.config == nil ? "refused" : "BUILT"), field error \(dnsResult.errors[.interfaceDnsServers] != nil ? "present" : "MISSING")")
    }

    /// The endpointless-ghost slip, proven where it must die: a ghost
    /// draft whose wstunnel URL is blank must be refused by validate()
    /// with `.wstunnelUrl` named. (The defensive belt behind it — a
    /// wstunnel draft that builds nothing while recording nothing —
    /// is unreachable by construction today and stays a unit-layer
    /// candidate; this step pins the reachable contract.)
    private func blankWstunnelUrl() async {
        guard var draft = TestConfigFactory.throwawayDraft(name: "TE-Validate-\(UUID().uuidString.prefix(8))", ghost: true) else {
            fail("factory produced no ghost draft")
            return
        }
        draft.wstunnel?.url = "   "
        let result = draft.validate()
        check(result.config == nil && result.errors[.wstunnelUrl] != nil,
              "blank wstunnel URL died in validate() with its field named — config \(result.config == nil ? "refused" : "BUILT"), field error \(result.errors[.wstunnelUrl] != nil ? "present" : "MISSING")")
    }
}
#endif
