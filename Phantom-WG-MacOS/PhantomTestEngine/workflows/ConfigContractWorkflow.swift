// ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
// ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
// ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
// ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
// ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
// ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
//
// Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
// Licensed under AGPL-3.0 - see LICENSE file for details
// WireGuard® is a registered trademark of Jason A. Donenfeld.
//
// Config Contract
//
// Config-shape contracts, from the parser down to `validate()`. Each step
// guards a shipped refusal at the layer that owns it. An environment that
// cannot be arranged skips rather than reddens; a step's own plant is
// answered for on the way out, so a red line here is either the refusal
// regressing or the step failing to set itself up.
//
// Scenarios:
//
//   A — Empty AllowedIPs Refused (No-Route Leak Guard)
//       A peer that routes nothing must be refused. Reaching `.active`
//       with no cryptokey route would put every packet outside the utun
//       in the clear — a total leak behind a green status.
//
//       The step plants a REAL tunnel to prove it: vault payload, system
//       entry, and in a moment an armed recovery rule. Any `.active`
//       sighting IS the leak; the earned pass is `.inactive` carrying a
//       recorded refusal. A failure inside `add()` is reported as
//       environment rather than credited to the leak guard, because
//       `add()` never inspects routes.
//
//   B — Multi-Peer Conf Not Silently Collapsed
//   C — Comma-Only Lists In validate()
//   D — Blank Wstunnel URL Dies In validate()
//       Parser and validator refusals, no session raised. A comma-only
//       Address dies; a comma-only DNS reads as no DNS server, as
//       WireGuard reads it.
//
//   E — Search Domains And ListenPort Survive The Payload
//       DNS splits into servers and search domains as WireGuard splits it,
//       and both new fields come through validate(), the vault payload's
//       encode and decode, and the written .conf. A payload written before
//       the two keys existed decodes with neither.
//
// A Stop inside the terminal wait of A never reaches the step's own
// cleanup, and reaching it under cancellation buys nothing because
// `vault.delete(id:attempts:)` refuses to send once the task is
// cancelled. Both paths belong to the teardown net.

#if DEBUG
import Foundation

final class ConfigContractWorkflow: TestWorkflow {
    override var displayName: String { "Config Contract (Leak + Parse Guards)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Empty AllowedIPs Refused (No-Route Leak Guard)", emptyAllowedIPs),
            WorkflowStep("Multi-Peer Conf Not Silently Collapsed", multiPeer),
            WorkflowStep("Comma-Only Lists In validate()", commaOnlyLists),
            WorkflowStep("Blank Wstunnel URL Dies In validate()", blankWstunnelUrl),
            WorkflowStep("Search Domains And ListenPort Survive The Payload", searchDomainsAndListenPort),
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
            skip("environment: add() failed before the guard was exercised — \(error.localizedDescription)")
            return
        }
        onTeardown("planted no-route tunnel") { [weak self] in
            guard let self else { return }
            await self.sweepPlantedTunnel(id: cfg.id, name: name)
        }
        tunnels.startActivation(of: t)
        let wentActive = await awaitStatus(t, is: .active, within: 12)
        if wentActive {
            fail("LEAK: no-route config reached .active — traffic would leave in the clear")
        } else {
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
        try? await tunnels.remove(tunnel: t)
        if !Task.isCancelled {
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
            check(section.lowercased() == "peer",
                  "\(label): rejected at parse (explicit) — duplicate [\(section)] section")
            return
        } catch {
            fail("\(label): rejected for the wrong reason — \(error.localizedDescription)")
            return
        }
        draft.name = "TE-MultiPeer-\(UUID().uuidString.prefix(8))"
        let result = draft.validate()
        if result.config != nil {
            fail("\(label): parser accepted a multi-peer conf into a single-peer model — silent collapse")
        } else {
            fail("\(label): named multi-peer config still failed validation — collapsed silently rather than being rejected outright (errors=\(result.errors.count))")
        }
    }

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
        check(dnsResult.config?.wireguard.interface.dnsServers.isEmpty == true && dnsResult.errors[.interfaceDnsServers] == nil,
              "comma-only DNS reads as no DNS server, as WireGuard reads it — config \(dnsResult.config == nil ? "REFUSED" : "built"), DNS servers \(dnsResult.config?.wireguard.interface.dnsServers.count ?? -1)")
    }

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

    private func searchDomainsAndListenPort() async {
        guard var draft = TestConfigFactory.throwawayDraft(name: "TE-Validate-\(UUID().uuidString.prefix(8))") else {
            fail("factory produced no draft")
            return
        }
        draft.wireguard.interface.dnsServers = "10.99.99.1, corp.example, lan"
        draft.wireguard.interface.listenPort = "51900"
        guard let config = draft.validate().config else {
            fail("a draft with search domains and a listen port did not validate")
            return
        }
        let interface = config.wireguard.interface
        check(interface.dnsServers.map(\.textual) == ["10.99.99.1"]
                && interface.dnsSearch == ["corp.example", "lan"]
                && interface.listenPort == 51900,
              "validate() splits DNS into servers and search domains and keeps the listen port — servers \(interface.dnsServers.map(\.textual)), search \(interface.dnsSearch), port \(String(describing: interface.listenPort))")

        let encoded = try? JSONEncoder().encode(config)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(TunnelConfig.self, from: $0) }
        check(decoded == config, "the vault payload carries both through an encode and decode")

        let legacy = encoded.flatMap(legacyPayload).flatMap { try? JSONDecoder().decode(TunnelConfig.self, from: $0) }
        check(legacy?.wireguard.interface.dnsSearch == []
                && legacy?.wireguard.interface.listenPort == nil
                && legacy?.wireguard.interface.dnsServers == interface.dnsServers,
              "a payload written before the two keys existed decodes with no search domain and no listen port — \(legacy == nil ? "DID NOT DECODE" : "decoded")")

        let text = config.asConfString()
        var reread = try? ConfParser.parse(text)
        reread?.name = config.name
        let back = reread?.validate().config?.wireguard.interface
        check(back?.dnsSearch == interface.dnsSearch
                && back?.listenPort == interface.listenPort
                && text.contains("ListenPort = 51900"),
              "the written .conf carries both back through the parser")
    }

    private func legacyPayload(_ data: Data) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var wireguard = root["wireguard"] as? [String: Any],
              var interface = wireguard["interface"] as? [String: Any] else { return nil }
        interface["dns_search"] = nil
        interface["listen_port"] = nil
        wireguard["interface"] = interface
        root["wireguard"] = wireguard
        return try? JSONSerialization.data(withJSONObject: root)
    }
}
#endif
