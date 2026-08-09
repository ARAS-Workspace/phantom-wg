#if DEBUG
import Foundation
import CryptoKit

/// Builds throwaway configs for workflows through the SAME pipeline a
/// user's import takes (`ConfParser.parse` → `TunnelDraft.validate`),
/// so a factory config is a real config in every mechanical sense.
///
/// The keys are genuine Curve25519 keypairs (freshly generated, never
/// reused), and every endpoint lives in TEST-NET-1 (192.0.2.0/24,
/// RFC 5737): routable nowhere, answered by nobody — a guaranteed,
/// deterministic negative. `AllowedIPs` stays inside TEST-NET too, so
/// even an "active" throwaway tunnel never captures real user traffic.
enum TestConfigFactory {

    /// A syntactically valid config that can never connect. Standalone
    /// by default; `ghost: true` adds a `[Wstunnel]` section (its URL
    /// also TEST-NET) for serialization-edge coverage.
    static func throwaway(name: String, ghost: Bool = false) -> TunnelConfig? {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let peerPublicKey = Curve25519.KeyAgreement.PrivateKey().publicKey

        var lines: [String] = []
        if ghost {
            lines += [
                "[Wstunnel]",
                "Url = wss://192.0.2.2:443",
                "Secret = phantom-test-secret",
                "Tunnel = udp://127.0.0.1:51999:192.0.2.2:51820",
                "",
            ]
        }
        lines += [
            "[Interface]",
            "PrivateKey = \(privateKey.rawRepresentation.base64EncodedString())",
            "Address = 10.99.99.2/32",
            "DNS = 10.99.99.1",
            "MTU = 1420",
            "",
            "[Peer]",
            "PublicKey = \(peerPublicKey.rawRepresentation.base64EncodedString())",
            "AllowedIPs = 192.0.2.0/24",
        ]
        if !ghost {
            lines.append("Endpoint = 192.0.2.1:51820")
        }
        lines.append("PersistentKeepalive = 25")

        guard var draft = try? ConfParser.parse(lines.joined(separator: "\n")) else { return nil }
        draft.name = name
        return draft.validate().config
    }
}
#endif
