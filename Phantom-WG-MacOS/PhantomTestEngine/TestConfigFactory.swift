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
// Test Engine: Throwaway Configurations
//
// Builds configurations that are structurally real and operationally
// inert: keys are generated fresh per call, every ROUTABLE address sits in
// a documentation or private range (TEST-NET-1 `192.0.2.0/24`,
// `10.99.99.0/24`), and the Ghost listener binds loopback — so nothing a
// run raises can reach a real peer.
//
// Four products, each for a different question:
//
//   throwaway(name:ghost:)        a valid standalone or Ghost config, built
//                                 through `ConfParser` so it carries
//                                 whatever the parser produces rather than
//                                 a hand-made struct
//   throwawayDraft(name:ghost:)   the same, stopped one step earlier at the
//                                 draft, for steps that need to edit or
//                                 validate before a config exists
//   emptyAllowedIPs(name:)        a `throwaway` config with its AllowedIPs
//                                 emptied by hand, because validation
//                                 refuses an empty list and the parser can
//                                 therefore never yield one
//   multiPeerConfText(secondHeader:)
//                                 raw `.conf` text with a second peer
//                                 section, for the parser's own refusals

#if DEBUG
import Foundation
import CryptoKit

enum TestConfigFactory {

    static func throwaway(name: String, ghost: Bool = false) -> TunnelConfig? {
        throwawayDraft(name: name, ghost: ghost)?.validate().config
    }

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

    static func emptyAllowedIPs(name: String) -> TunnelConfig? {
        guard let base = throwaway(name: name) else { return nil }
        var wg = base.wireguard
        wg.peer.allowedIPs = []
        return TunnelConfig(id: base.id, name: name, wireguard: wg, wstunnel: nil)
    }

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
