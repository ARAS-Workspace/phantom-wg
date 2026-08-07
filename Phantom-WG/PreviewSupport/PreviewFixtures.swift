import Foundation
import NetworkExtension

/// Deterministic sample data for SwiftUI previews. Everything here is
/// display-plausible but operationally inert: keys are pattern bytes
/// and endpoints sit in the TEST-NET documentation ranges, so canvas
/// interactions never touch real preferences or the Keychain.
@MainActor
enum PreviewFixtures {

    // MARK: - Typed Value Helpers

    /// Fixture values are compile-time constants; a parse failure is a
    /// programming error, so it traps loudly instead of propagating.
    private static func parsed<T>(_ make: @autoclosure () throws -> T) -> T {
        do {
            return try make()
        } catch {
            fatalError("Invalid preview fixture: \(error)")
        }
    }

    /// 32 deterministic pattern bytes → valid base64 WireGuard key.
    /// Distinct `seed`s yield visually distinct keys.
    static func key(seed: UInt8) -> WireGuardKey {
        let bytes = (0..<32).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 7) }
        return parsed(try WireGuardKey(parsing: Data(bytes).base64EncodedString()))
    }

    // MARK: - Tunnel Configs

    /// Ghost-mode config: WireGuard riding a wstunnel bridge. Carries
    /// no peer endpoint — in Ghost mode the endpoint is system-defined
    /// from the wstunnel listener.
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

    /// Standalone WireGuard config — no wstunnel section.
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

    /// `TunnelsManager` wired entirely to in-memory providers. The
    /// default set mirrors a realistic operator device: one live
    /// ghost tunnel, one standalone relay, one parked config.
    static func tunnelsManager(providers: [PreviewTunnelProvider]? = nil) -> TunnelsManager {
        let list = providers ?? [
            provider(config: ghostConfig(), status: .connected, logLines: logLines),
            provider(config: wireguardConfig()),
            provider(config: ghostConfig(name: "Home Lab"))
        ]
        return TunnelsManager(
            tunnelProviders: list,
            providerFactory: PreviewTunnelProviderFactory(providers: list)
        )
    }

    /// Activation failure for error-state previews; the wrapped
    /// error's `localizedDescription` is what the UI renders.
    static var activationError: TunnelActivationError {
        .retryLimitReached(lastSystemError: NSError(
            domain: "PreviewFixtures",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The VPN session failed to establish."]
        ))
    }

    // MARK: - Logs

    /// Extension-side log feed served through opcode `1`, tagged the
    /// way the tunnel extension tags its subsystems (WS/WG/TUN).
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

    /// Ready-made rows for previews that feed a `LogEntryProvider`
    /// directly instead of polling a provider.
    static var logEntries: [LogEntry] {
        logLines.enumerated().map { index, line in
            LogEntry(
                id: index,
                tag: line.tag,
                timestamp: line.timestamp,
                text: "[\(line.timestamp)][\(line.tag)] \(line.message)"
            )
        }
    }
}
