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
        throwawayDraft(name: name, ghost: ghost)?.validate().config
    }

    /// The same throwaway, stopped one stage earlier: the DRAFT, for
    /// steps that prove validate()-layer refusals by bending one field
    /// at a time and asking for the named error.
    static func throwawayDraft(name: String, ghost: Bool = false) -> TunnelDraft? {
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
        return draft
    }

    /// A config whose peer allows no IPs at all. The typed model
    /// permits an empty `allowedIPs` array, so this is built through
    /// the memberwise initializers rather than the parser (which needs
    /// the key present). If such a config can go Active, every packet
    /// leaves in the clear — the builder must refuse it. Standalone.
    static func emptyAllowedIPs(name: String) -> TunnelConfig? {
        guard let base = throwaway(name: name) else { return nil }
        var wg = base.wireguard
        wg.peer.allowedIPs = []
        return TunnelConfig(id: base.id, name: name, wireguard: wg, wstunnel: nil)
    }

    /// Raw `.conf` text carrying two peer sections. Not parsed here —
    /// handed to the workflow so it can prove the parser refuses it
    /// with the `.duplicateSection` identity; while the typed model
    /// stays single-peer, any acceptance would be a silent collapse
    /// and fails the step outright. `secondHeader` lets the workflow
    /// drive the spelling VARIANTS of the second header — "[Peer ]"
    /// with a stray inner space once minted a distinct section that
    /// dodged the guard entirely.
    static func multiPeerConfText(secondHeader: String = "[Peer]") -> String {
        let iface = Curve25519.KeyAgreement.PrivateKey()
        let peerA = Curve25519.KeyAgreement.PrivateKey().publicKey
        let peerB = Curve25519.KeyAgreement.PrivateKey().publicKey
        return [
            "[Interface]",
            "PrivateKey = \(iface.rawRepresentation.base64EncodedString())",
            "Address = 10.99.99.2/32",
            "DNS = 10.99.99.1",
            "MTU = 1420",
            "",
            "[Peer]",
            "PublicKey = \(peerA.rawRepresentation.base64EncodedString())",
            "AllowedIPs = 192.0.2.0/25",
            "Endpoint = 192.0.2.1:51820",
            "PersistentKeepalive = 25",
            "",
            secondHeader,
            "PublicKey = \(peerB.rawRepresentation.base64EncodedString())",
            "AllowedIPs = 192.0.2.128/25",
            "Endpoint = 192.0.2.2:51820",
            "PersistentKeepalive = 25",
        ].joined(separator: "\n")
    }
}
#endif
