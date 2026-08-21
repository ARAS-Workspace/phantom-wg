import Foundation
import NetworkExtension

@MainActor
enum PreviewFixtures {

    // MARK: - Typed Value Helpers

    private static func parsed<T>(_ make: @autoclosure () throws -> T) -> T {
        do {
            return try make()
        } catch {
            fatalError("Invalid preview fixture: \(error)")
        }
    }

    static func key(seed: UInt8) -> WireGuardKey {
        let bytes = (0..<32).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 7) }
        return parsed(try WireGuardKey(parsing: Data(bytes).base64EncodedString()))
    }

    // MARK: - Tunnel Configs

    static func ghostConfig(name: String = "Istanbul Edge") -> TunnelConfig {
        TunnelConfig(
            name: name,
            createdAt: Date(timeIntervalSinceReferenceDate: 790_000_000),
            wireguard: wireguardPayload(seed: 10, endpoint: nil),
            wstunnel: WstunnelConfig(
                url: parsed(try WstunnelURL(parsing: "wss://edge.phantom.tc")),
                secret: "preview-secret",
                localHost: "127.0.0.1",
                localPort: 51_820,
                remoteHost: "127.0.0.1",
                remotePort: 51_820
            )
        )
    }

    static func wireguardConfig(name: String = "Frankfurt Relay") -> TunnelConfig {
        TunnelConfig(
            name: name,
            createdAt: Date(timeIntervalSinceReferenceDate: 789_000_000),
            wireguard: wireguardPayload(
                seed: 40,
                endpoint: parsed(try IPEndpoint(parsing: "192.0.2.10:51820"))
            )
        )
    }

    private static func wireguardPayload(seed: UInt8, endpoint: IPEndpoint?) -> WireguardConfig {
        WireguardConfig(
            interface: InterfaceConfig(
                privateKey: key(seed: seed),
                addresses: [
                    parsed(try AddressWithPrefix(parsing: "10.7.0.2/32")),
                    parsed(try AddressWithPrefix(parsing: "fd00:7::2/128"))
                ],
                dnsServers: [
                    parsed(try IPAddressEntry(parsing: "1.1.1.1")),
                    parsed(try IPAddressEntry(parsing: "9.9.9.9"))
                ],
                mtu: 1_420
            ),
            peer: PeerConfig(
                publicKey: key(seed: seed &+ 1),
                presharedKey: key(seed: seed &+ 2),
                allowedIPs: [
                    parsed(try AddressWithPrefix(parsing: "0.0.0.0/0")),
                    parsed(try AddressWithPrefix(parsing: "::/0"))
                ],
                endpoint: endpoint,
                persistentKeepalive: 25
            )
        )
    }

    // MARK: - Providers & Manager

    static func provider(
        config: TunnelConfig,
        status: NEVPNStatus = .disconnected,
        logLines: [PreviewTunnelProvider.LogLine] = []
    ) -> PreviewTunnelProvider {
        PreviewTunnelProvider(config: config, status: status, logLines: logLines)
    }

    static func tunnelsManager(providers: [PreviewTunnelProvider]? = nil) -> TunnelsManager {
        let list = providers ?? [
            provider(config: ghostConfig(), status: .connected, logLines: logLines),
            provider(config: wireguardConfig()),
            provider(config: ghostConfig(name: "Home Lab"))
        ]
        return TunnelsManager(
            tunnelProviders: list,
            providerFactory: PreviewTunnelProviderFactory(providers: list),
            vault: vaultClient(for: list)
        )
    }

    static func vaultClient(for providers: [PreviewTunnelProvider]) -> TunnelVaultClient {
        PreviewVaultClient(configs: providers.compactMap(\.config))
    }

    static var activationError: TunnelActivationError {
        .retryLimitReached(lastSystemError: NSError(
            domain: "PreviewFixtures",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The VPN session failed to establish."]
        ))
    }

    // MARK: - Logs

    static var logLines: [PreviewTunnelProvider.LogLine] {
        [
            .init(timestamp: "12:04:07", tag: "WS", message: "wstunnel connecting to wss://edge.phantom.tc"),
            .init(timestamp: "12:04:07", tag: "WS", message: "websocket established (tls, http/1.1 upgrade)"),
            .init(timestamp: "12:04:08", tag: "TUN", message: "utun6 configured mtu=1420"),
            .init(timestamp: "12:04:08", tag: "WG", message: "sending handshake initiation to peer"),
            .init(timestamp: "12:04:08", tag: "WG", message: "received handshake response, session established"),
            .init(timestamp: "12:04:09", tag: "TUN", message: "routes installed: 0.0.0.0/0, ::/0 via utun6"),
            .init(timestamp: "12:04:21", tag: "WG", message: "keepalive sent (25s interval)")
        ]
    }

    static var logEntries: [LogEntry] {
        logLines.enumerated().map { index, line in
            LogEntry(
                id: index,
                tag: line.tag,
                text: "[\(line.timestamp)][\(line.tag)] \(line.message)"
            )
        }
    }

    // MARK: - Split Tunneling

    static var appEntries: [AppEntry] {
        [
            AppEntry(
                signingIdentifier: "com.apple.Safari",
                bundleIdentifier: "com.apple.Safari",
                displayName: "Safari",
                lastKnownPath: "/Applications/Safari.app"
            ),
            AppEntry(
                signingIdentifier: "9BNSXJN65R.com.tinyspeck.slackmacgap",
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                displayName: "Slack",
                teamName: "Slack Technologies",
                lastKnownPath: "/Applications/Slack.app"
            ),
            AppEntry(
                signingIdentifier: "5UKK4XLW32.org.videolan.vlc",
                bundleIdentifier: "org.videolan.vlc",
                displayName: "VLC",
                teamName: "VideoLAN",
                lastKnownPath: "/Applications/VLC.app"
            )
        ]
    }

    static func splitStore(
        enabled: Bool = true,
        apps: [AppEntry]? = nil,
        selection: InterfaceSelection = .auto
    ) -> SplitTunnelingStore {
        let configuration = SplitTunnelingConfiguration(
            isEnabled: enabled,
            interfaceSelection: selection,
            apps: apps ?? appEntries
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phantom-preview-split-\(UUID().uuidString).json")
        if let data = try? JSONEncoder().encode(configuration) {
            try? data.write(to: url, options: .atomic)
        }
        return SplitTunnelingStore(fileURL: url)
    }

    static func sessionCoordinator(
        state: SplitTunnelingSessionCoordinator.State = .stopped
    ) -> SplitTunnelingSessionCoordinator {
        SplitTunnelingSessionCoordinator(
            split: SplitTunnelProviderManager(),
            dns: DNSProxyProviderManager(),
            dnsDaemonClient: DNSProxyDaemonClient(),
            splitDaemonClient: SplitTunnelDaemonClient(),
            state: state
        )
    }

    // MARK: - Vault Session

    static func vaultSession(state: TunnelVaultSession.State = .ready) -> TunnelVaultSession {
        let client = PreviewVaultClient(configs: [])
        switch state {
        case .connecting:
            client.pingAnswer = nil
        case .ready:
            client.pingAnswer = .ready(payloads: 0, identity: ExtensionIdentity.current)
        case .silent:
            client.pingAnswer = .unreachable
        case .doorFailed:
            client.pingAnswer = .doorFailed(identity: ExtensionIdentity.current)
        }
        return TunnelVaultSession(vault: client, state: state)
    }

    // MARK: - Extension Gate

    static func gateController(
        titleKey: String,
        status: ExtensionGateController.Status
    ) -> ExtensionGateController {
        ExtensionGateController(
            bundleID: "com.remrearas.Phantom-WG-MacOS.preview",
            displayName: LocalizationManager.shared.t(titleKey),
            status: status
        )
    }

    static func gateCoordinator(
        tunnel: ExtensionGateController.Status = .activated,
        split: ExtensionGateController.Status = .activated,
        dns: ExtensionGateController.Status = .activated
    ) -> ExtensionGateCoordinator {
        ExtensionGateCoordinator(
            tunnel: gateController(titleKey: "gate_ext_tunnel", status: tunnel),
            split: gateController(titleKey: "gate_ext_split", status: split),
            dns: gateController(titleKey: "gate_ext_dns", status: dns)
        )
    }
}
