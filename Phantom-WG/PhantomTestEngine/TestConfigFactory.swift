// Test Engine: Throwaway Configurations
//
// Builds configurations that are structurally real and operationally
// inert: keys are generated fresh per call, every ROUTABLE address sits in
// a documentation or private range (TEST-NET-1 `192.0.2.0/24`,
// `10.99.99.0/24`), and the Ghost listener binds loopback — so nothing a
// run raises can reach a real peer.
//
// The products, each for a different question:
//
//   throwaway(name:ghost:)        a valid standalone or Ghost config, built
//                                 through `ConfParser` so it carries
//                                 whatever the parser produces rather than
//                                 a hand-made struct
//   throwawayDraft(name:ghost:)   the same, stopped one step earlier at the
//                                 draft, for steps that need to edit or
//                                 validate before a config exists
//   multiPeerConfText(secondHeader:)
//                                 raw `.conf` text with a second peer
//                                 section, for the parser's own refusals
//   confText(interface:peer:wstunnel:)
//                                 `.conf` text around the lines a table
//                                 row is about, with fresh keys filled in
//   validated(_:)                 that text through the parser and
//                                 `validate()`, as the import screen runs
//                                 it: the config, the field errors, or the
//                                 parse error

#if DEBUG
import Foundation
import CryptoKit

enum TestConfigFactory {

    static func privateKey() -> String {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString()
    }

    static func publicKey() -> String {
        Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    }

    static func throwaway(name: String, ghost: Bool = false) -> TunnelConfig? {
        throwawayDraft(name: name, ghost: ghost)?.validate().config
    }

    static func throwawayDraft(name: String, ghost: Bool = false) -> TunnelDraft? {
        var lines: [String] = []
        if ghost {
            lines += [
                "[Wstunnel]",
                "Url = wss://192.0.2.2:443",
                "Secret = phantom-test-secret",
                "Tunnel = udp://127.0.0.1:51999:192.0.2.2:51820",
                ""
            ]
        }
        lines += [
            "[Interface]",
            "PrivateKey = \(privateKey())",
            "Address = 10.99.99.2/32",
            "DNS = 10.99.99.1",
            "MTU = 1420",
            "",
            "[Peer]",
            "PublicKey = \(publicKey())",
            "AllowedIPs = 192.0.2.0/24"
        ]
        if !ghost {
            lines.append("Endpoint = 192.0.2.1:51820")
        }
        lines.append("PersistentKeepalive = 25")

        guard var draft = try? ConfParser.parse(lines.joined(separator: "\n")) else { return nil }
        draft.name = name
        return draft
    }

    static func multiPeerConfText(secondHeader: String = "[Peer]") -> String {
        [
            "[Interface]",
            "PrivateKey = \(privateKey())",
            "Address = 10.99.99.2/32",
            "DNS = 10.99.99.1",
            "MTU = 1420",
            "",
            "[Peer]",
            "PublicKey = \(publicKey())",
            "AllowedIPs = 192.0.2.0/25",
            "Endpoint = 192.0.2.1:51820",
            "PersistentKeepalive = 25",
            "",
            secondHeader,
            "PublicKey = \(publicKey())",
            "AllowedIPs = 192.0.2.128/25",
            "Endpoint = 192.0.2.2:51820",
            "PersistentKeepalive = 25"
        ].joined(separator: "\n")
    }

    static func confText(interface: String, peer: String, wstunnel: String? = nil) -> String {
        (wstunnel.map { "[Wstunnel]\n\($0)\n\n" } ?? "")
            + "[Interface]\nPrivateKey = \(privateKey())\n\(interface)\n\n"
            + "[Peer]\nPublicKey = \(publicKey())\n\(peer)\n"
    }

    struct Validated {
        let config: TunnelConfig?
        let errors: [TunnelDraft.Field: FieldValidationError]
        let parseError: Error?

        var parseErrorName: String {
            parseError.map { String(describing: $0) } ?? "-"
        }
    }

    static func validated(_ text: String, name: String = "TE-Validate") -> Validated {
        do {
            var draft = try ConfParser.parse(text)
            draft.name = name
            let result = draft.validate()
            return Validated(config: result.config, errors: result.errors, parseError: nil)
        } catch {
            return Validated(config: nil, errors: [:], parseError: error)
        }
    }
}
#endif
