# ADR-0010 — DNS Is Separated At The Flow's Entry, Not In A Rule

## Status

Accepted — 2026-11-15

This is an **extension record**: it narrows an accepted record by the route [ADR-0001 Item 5](0001-architectural-decision-records.md#decision) describes. The record it narrows is ADR-0003. The text of ADR-0003 does not change. This record replaces only the mechanism of its item 2.

- Fix: split tunnel declines DNS flows in code, without port 53 rules ([8d43957](https://github.com/ARAS-Workspace/phantom-wg/commit/8d43957ca1afd5c930a183232029335fdec0bba3))

- Refactor: proxy extensions use the macOS 15 flow endpoint APIs ([90b85ab](https://github.com/ARAS-Workspace/phantom-wg/commit/90b85ab27d1330ea0154ff20a110d3eaf0aa0f4f))

## Context

**Record narrowed:** [ADR-0003 Split-Tunneling and DNS-Proxy Architecture](0003-split-tunneling-and-dns-proxy-architecture.md), item 2 of its [Decision](0003-split-tunneling-and-dns-proxy-architecture.md#decision) section.

**Source:** `PhantomSplitTunnel/App/TransparentProxyProvider.swift`, `PhantomSplitTunnel/Features/FlowFiltering/TCPFlowRelay.swift`, `PhantomSplitTunnel/Features/FlowFiltering/UDPFlowRelay.swift`, `PhantomDNSProxy/App/DNSProxyProvider.swift`, `PhantomDNSProxy/Features/DNSFlowRelay.swift`, `project.yml`. Commits [`8d43957`](https://github.com/ARAS-Workspace/phantom-wg/commit/8d43957ca1afd5c930a183232029335fdec0bba3) and [`90b85ab`](https://github.com/ARAS-Workspace/phantom-wg/commit/90b85ab27d1330ea0154ff20a110d3eaf0aa0f4f).

ADR-0003 kept the DNS flow in the DNS Proxy lane with a carve-out at the network-rule level. `PhantomSplitTunnel` put four rules for port 53 into `excludedNetworkRules`. The rules covered the `0.0.0.0` and `::` addresses separately for UDP and TCP. ADR-0003 recorded this route as the only mechanism of the DNS lane.

This mechanism does not work on macOS 15. `nesessionmanager` rejects Split-Tunnel's Transparent Proxy session with the error `53 cannot be specified as the port for transparent proxy network rules`, once for each of the four rules, and removes the session. The DNS Proxy keeps running. Because the Transparent Proxy does not run, the listed applications' traffic is not steered to the physical interface. The carve-out has shipped since `mac-v2.1.0`. That the error has existed on macOS 15 since that release is read from the code's history. The measured installation is on the development virtual machine.

These rules broke the SDK's written contract from the start. The `NETransparentProxyNetworkSettings.h` header states, for `includedNetworkRules` and `excludedNetworkRules`, that port 53 cannot be used and that DNS traffic can only be matched by domain-based rules. The same sentence is in the macOS 10.15 SDK, so the API has carried the same contract since the day it arrived. macOS 27.0.1 does not reject these rules. That is why the carve-out appeared to work in the development environment.

My notes from that period say that returning `false` did not work. According to the notes, a separation was needed, and it had to be solved at a lower layer before the flow reached this point. The `TransparentProxyProvider` of that time overrode only `handleNewFlow`. A UDP flow's destination was not visible there. The destination is visible only at the initial endpoint of `handleNewUDPFlow`. macOS 15 opened this entry to Swift through `NEAppProxyUDPFlowHandling`.

Apple DTS's guidance on this points the same way. DNS flows are handled specially in the Transparent Proxy subsystem, and a DNS Proxy should be used to capture DNS ([Apple Developer Forums, DTS, December 2025](https://developer.apple.com/forums/thread/809317)).

### Narrowed Item

| ADR-0003 | Bound until now | With this decision | Source |
| --- | --- | --- | --- |
| **Item 2** Carve-out at the network-rule level | There are four rules for port 53 in `excludedNetworkRules`. Excluding port 53 by rule is the only mechanism of the DNS lane. | The network rules carry no port 53. The Transparent Proxy recognises a flow to 53 at its entry and returns `false`. The flow falls to the DNS Proxy. | `TransparentProxyProvider.swift`, commit `8d43957` |

### Measurements

- **macOS 15 (development VM, 2026-11-15):** before the fix, `nesessionmanager` wrote four rejection lines and the Split-Tunnel session was removed. After the fix the session opens and the Split-Tunnel log writes the line `interface resolved: en0 (wiredEthernet)`.
- **macOS 27.0.1 (development machine, 2026-11-15):** the system log has no rejection line in the last three days. Split-Tunnel sessions connected while the carve-out was in place as well.
- **Order (macOS 27.0.1, 2026-11-15):** a flow reaches the Transparent Proxy first. If the Transparent Proxy declines it, the DNS Proxy captures it. With the System DNS Resolver on, the Split-Tunnel log wrote `System DNS (mDNSResponder) — DNS left to the system  UDP  2620:fe::fe:53` lines between 13:06:16.396 and 13:06:16.398. The DNS-Proxy log wrote `MATCHED System DNS (mDNSResponder) UDP → 1.1.1.1:53 via en0` lines between 13:06:16.398 and 13:06:16.404.
- **A port 53 flow arriving with an application identity (macOS 27.0.1, 2026-11-15):** UDP 53 flows arriving with Brave's identity also reached the Transparent Proxy and were declined with the line `Brave Browser — DNS left to the system  UDP  2620:fe::9:53`. In the same session the DNS-Proxy log wrote `MATCHED Brave Browser UDP → 1.1.1.1:53 via en0` lines.

## Decision

DNS is separated not in a network rule but where the flow enters the Transparent Proxy. Concretely:

1. **The network rules carry no port 53.** `PhantomSplitTunnel` sets only the dual-stack wildcard `includedNetworkRules` rule. `excludedNetworkRules` is not used.

2. **A flow to 53 is declined at its entry.** A TCP flow is recognised in `handleNewFlow` by `remoteFlowEndpoint`, a UDP flow in `handleNewUDPFlow(_:initialRemoteFlowEndpoint:)` by its initial endpoint. If the port is 53, both entries return `false`. If the flow belongs to a listed application, a `DNS left to the system` line is written to the Split-Tunnel log.

3. **The DNS lane stays in the DNS Proxy.** The DNS Proxy captures the declined flow and carries it to the physical interface's resolver as described in ADR-0003. The separation between the two extensions that ADR-0003 set up does not change.

This decision does not touch the number of extensions, the control channel or the System DNS Resolver toggle. It changes only the route by which the DNS flow separates from the Transparent Proxy.

## Consequences

- Split-Tunnel starts again on macOS 15. Installed 2.1.x extensions keep failing to start on macOS 15 until the new release is installed.
- The code follows the SDK's written contract for Transparent Proxy network rules. Which macOS release began enforcing that contract no longer affects the behaviour.
- The separation rests on an order Apple has not documented. A flow reaches the Transparent Proxy first and the DNS Proxy after it. If the order changes in a macOS release, the DNS lane breaks. The check can be measured. The `DNS left to the system` lines in the Split-Tunnel log must be met at the same moment by `MATCHED` lines in the DNS-Proxy log.
- Flows that go straight to 53 with an application identity (Brave in the measurement) also reach the Transparent Proxy and are declined the same way. The Split-Tunnel log shows these flows too.
- Because the decision rests on macOS 15's UDP entry, the floor of the two proxy extensions joined the app's floor and became 15.1. The extensions use macOS 15's `NWEndpoint`-based flow APIs, and the deprecated `NWHostEndpoint` family no longer appears in the code. Since the extensions run only on systems where the app installs them, the range of supported systems did not change.

## Related Records

- [ADR-0003](0003-split-tunneling-and-dns-proxy-architecture.md) item 2: narrowed in the table above. The record's other items did not change. The separation of the two extensions and the DNS Proxy's DNS lane carry this record too.
- [ADR-0004](0004-unified-proxy-config-daemon.md): the control channel of the two proxy extensions. Unchanged.
- [ADR-0001](0001-architectural-decision-records.md) item 5: how this record comes to exist. An accepted ADR is not changed for a correction, a new record that narrows it is opened.
