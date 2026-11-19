// Config Contract
//
// Config-shape contracts, from the parser down to `validate()`, the
// payload the Keychain holds and the two values the tunnel detail shows
// in place of a secret. Nothing here raises a session or touches a
// store. A, B and C read `.conf` text through `ConfParser.parse` and
// `TunnelDraft.validate()`, the way the import and edit screens run it.
// B also runs `validate()` on two drafts the parser refuses, built or
// edited by hand, and C also encodes and decodes the payload and reads
// back the `.conf` text a configuration writes. D derives public keys
// and secret fingerprints from fixed keys and secrets. A check in A, B
// or C names its row, so a red line says which rule regressed.
//
// Scenarios:
//
//   A — The .conf Reading Follows WireGuardKit (ADR-0011)
//       R1-R14: an address without a prefix is a host route, a prefix past
//       the family's limit is clipped, a missing MTU, keepalive or DNS
//       reads as automatic, off and none, an inline `#` comment is dropped
//       outside `[Wstunnel]` and kept inside it, and an unknown key, an
//       unknown section, a line without `=` and a repeated single-value
//       key are errors while a repeated Address merges.
//
//   B — Leak Guards And Belts Refuse What They Must
//       A comma-only AllowedIPs or Address, a standalone peer without an
//       Endpoint, a second `[Peer]` (exact and with a stray space inside
//       the brackets), a blank wstunnel URL: each is refused, and the
//       draft-level refusal names its field.
//
//   C — Search Domains And ListenPort Survive The Payload
//       M1-M11: DNS splits into servers and search domains, ListenPort is
//       read and bounded, both go through the payload's encode and decode
//       and through the written `.conf`, a payload written before the two
//       keys existed decodes with neither, and automatic MTU and keepalive
//       off survive the text.
//
//   D — Secretless Detail: Public Key And Secret Fingerprint
//       The public key derived from RFC 7748's two private keys is the RFC's
//       public key, and the secret fingerprint equals an HMAC-SHA256 value
//       computed outside this app (Python's `hmac`, 2026-11-18) for a fixed
//       key and secret; another secret or key gives another fingerprint,
//       an empty secret gives none, and none carries the secret's text.

#if DEBUG
import Foundation

final class ConfigContractWorkflow: TestWorkflow {
    override var displayName: String { "Config Contract (Reading, Guards, Payload)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("The .conf Reading Follows WireGuardKit (ADR-0011)", confReading),
            WorkflowStep("Leak Guards And Belts Refuse What They Must", leakGuardsAndBelts),
            WorkflowStep("Search Domains And ListenPort Survive The Payload", searchDomainsAndListenPort),
            WorkflowStep("Secretless Detail: Public Key And Secret Fingerprint", secretlessDetail)
        ]
    }

    private let endpoint = "Endpoint = 192.0.2.10:51820"

    private func standalone(_ interface: String, _ peer: String = "AllowedIPs = 0.0.0.0/0") -> TestConfigFactory.Validated {
        TestConfigFactory.validated(TestConfigFactory.confText(interface: interface, peer: "\(peer)\n\(endpoint)"))
    }

    // MARK: - A

    func confReading() async {
        var row = standalone("Address = 10.0.0.2")
        check(row.config?.wireguard.interface.addresses.first?.textual == "10.0.0.2/32",
              "R1 an unprefixed IPv4 address reads /32")
        row = TestConfigFactory.validated(TestConfigFactory.confText(interface: "Address = fd00::2",
                                                                     peer: "AllowedIPs = ::/0\n\(endpoint)"))
        check(row.config?.wireguard.interface.addresses.first?.textual == "fd00::2/128",
              "R2 an unprefixed IPv6 address reads /128")
        row = standalone("Address = 10.0.0.2/40")
        check(row.config?.wireguard.interface.addresses.first?.textual == "10.0.0.2/32",
              "R3 a prefix past the limit is clipped")
        row = standalone("Address = fd00::2/129", "AllowedIPs = ::/0")
        check(row.config?.wireguard.interface.addresses.first?.textual == "fd00::2/128",
              "R3 an IPv6 prefix past the limit is clipped")
        row = standalone("Address = 10.0.0.2/32")
        check(row.config?.wireguard.interface.mtu == 0, "R4 a missing MTU is 0, automatic")
        check(row.config?.wireguard.peer.persistentKeepalive == 0, "R5 a missing PersistentKeepalive is 0, off")
        check(row.config?.wireguard.interface.dnsServers.isEmpty == true,
              "R6 a missing DNS is no DNS server")
        row = standalone("Address = 10.0.0.2/32\nMTU = 65535")
        check(row.config?.wireguard.interface.mtu == 65535, "R7 MTU accepts 0...65535")
        row = standalone("Address = 10.0.0.2/32\nMTU = 1280 # small", "AllowedIPs = 0.0.0.0/0 # all")
        check(row.config?.wireguard.interface.mtu == 1280 && row.config?.wireguard.peer.allowedIPs.count == 1,
              "R8 an inline # comment is dropped in [Interface] and [Peer]")
        row = TestConfigFactory.validated(TestConfigFactory.confText(
            interface: "Address = 10.0.0.2/32", peer: "AllowedIPs = 0.0.0.0/0",
            wstunnel: "Url = wss://edge.example.test\nSecret = a#b\nTunnel = udp://127.0.0.1:51820:127.0.0.1:51820"))
        check(row.config?.wstunnel?.secret == "a#b", "R9 # is kept inside [Wstunnel]")
        row = standalone("Address = 10.0.0.2/32\nPostUp = echo")
        check(row.parseErrorName.hasPrefix("unknownKey"), "R10 an unknown key is an error (\(row.parseErrorName))")
        row = TestConfigFactory.validated(TestConfigFactory.confText(interface: "Address = 10.0.0.2/32",
                                                                     peer: "AllowedIPs = 0.0.0.0/0\n\(endpoint)")
                                          + "\n[Foo]\nBar = 1\n")
        check(row.parseErrorName.hasPrefix("invalidLine"), "R11 an unknown section is an error (\(row.parseErrorName))")
        row = standalone("Address = 10.0.0.2/32\njunk")
        check(row.parseErrorName.hasPrefix("invalidLine"), "R12 a line without = is an error (\(row.parseErrorName))")
        row = standalone("Address = 10.0.0.2/32\nMTU = 1280\nMTU = 1300")
        check(row.parseErrorName.hasPrefix("duplicateKey"),
              "R13 a repeated single-value key is an error (\(row.parseErrorName))")
        row = standalone("Address = 10.0.0.2/32\nAddress = fd00::2/128")
        check(row.config?.wireguard.interface.addresses.count == 2, "R14 a repeated Address merges")
    }

    // MARK: - B

    func leakGuardsAndBelts() async {
        var row = standalone("Address = 10.0.0.2/32", "AllowedIPs = ,")
        check(row.config == nil && row.errors[.peerAllowedIPs] == .empty,
              "G1 a comma-only AllowedIPs is refused on its field (no-route leak guard)")
        row = standalone("Address = ,")
        check(row.config == nil && row.errors[.interfaceAddresses] == .empty,
              "G2 a comma-only Address is refused on its field")
        row = TestConfigFactory.validated(TestConfigFactory.confText(interface: "Address = 10.0.0.2/32",
                                                                     peer: "AllowedIPs = 0.0.0.0/0"))
        check(row.parseErrorName.hasPrefix("missingKey"),
              "G3 a standalone peer without an Endpoint is refused (\(row.parseErrorName))")
        for (label, header) in [("exact [Peer]", "[Peer]"), ("spaced [Peer ]", "[Peer ]")] {
            let multi = TestConfigFactory.validated(TestConfigFactory.multiPeerConfText(secondHeader: header))
            check(multi.parseErrorName.hasPrefix("duplicateSection"),
                  "G4 a second peer section, \(label), is refused at parse (\(multi.parseErrorName))")
        }
        let draft = TunnelDraft(name: "TE-Validate", wireguard: WireguardDraft(
            interface: InterfaceDraft(privateKey: TestConfigFactory.privateKey(), addresses: "10.0.0.2/32",
                                      dnsServers: "", mtu: ""),
            peer: PeerDraft(publicKey: TestConfigFactory.publicKey(), presharedKey: "", allowedIPs: "0.0.0.0/0",
                            endpoint: "", persistentKeepalive: "")))
        let result = draft.validate()
        check(result.config == nil && result.errors[.peerEndpoint] == .empty,
              "B1 a standalone draft without an endpoint names the endpoint field")
        if var ghost = TestConfigFactory.throwawayDraft(name: "TE-Validate", ghost: true) {
            ghost.wstunnel?.url = "   "
            let blank = ghost.validate()
            check(blank.config == nil && blank.errors[.wstunnelUrl] != nil,
                  "B2 a blank wstunnel URL dies in validate() with its field named")
        } else {
            fail("the config factory produced no ghost draft")
        }
    }

    // MARK: - C

    func searchDomainsAndListenPort() async {
        var row = standalone("Address = 10.0.0.2/32\nDNS = 1.1.1.1, corp.example, 2606:4700::1111\nListenPort = 51820")
        check(row.config?.wireguard.interface.dnsServers.map(\.textual) == ["1.1.1.1", "2606:4700::1111"],
              "M1 the DNS servers are the IP entries")
        check(row.config?.wireguard.interface.dnsSearch == ["corp.example"], "M2 a non-IP DNS entry is a search domain")
        check(row.config?.wireguard.interface.listenPort == 51820, "M3 ListenPort is read")
        row = standalone("Address = 10.0.0.2/32\nListenPort = 70000")
        check(row.config == nil && row.errors[.interfaceListenPort] == .intOutOfRange(value: 70000, min: 0, max: 65535),
              "M4 a ListenPort past 65535 is refused on its field")
        row = standalone("Address = 10.0.0.2/32\nDNS = ,")
        check(row.config != nil && row.config?.wireguard.interface.dnsServers.isEmpty == true
                && row.config?.wireguard.interface.dnsSearch.isEmpty == true,
              "M5 a comma-only DNS is no DNS, as WireGuard reads it")

        guard let full = standalone("Address = 10.0.0.2/32\nDNS = 9.9.9.9, corp.example\nListenPort = 51820").config,
              let data = try? JSONEncoder().encode(full) else {
            fail("M6 the payload rows could not be arranged")
            return
        }
        check((try? JSONDecoder().decode(TunnelConfig.self, from: data)) == full,
              "M6 the payload round trip keeps search domains and ListenPort")
        let interface = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["wireguard"] as? [String: Any] }
            .flatMap { $0["interface"] as? [String: Any] }
        check(interface?["dns_search"] != nil && interface?["listen_port"] != nil,
              "M7 the payload carries dns_search and listen_port")
        let legacy = legacyPayload(data).flatMap { try? JSONDecoder().decode(TunnelConfig.self, from: $0) }
        check(legacy != nil && legacy?.wireguard.interface.dnsSearch.isEmpty == true
                && legacy?.wireguard.interface.listenPort == nil,
              "M8 a payload without the two keys decodes with neither")
        let text = full.asConfString()
        check(text.contains("ListenPort = 51820") && text.contains("DNS = 9.9.9.9, corp.example"),
              "M9 the .conf text writes ListenPort and DNS with its search domains")
        var again = try? ConfParser.parse(text)
        again?.name = full.name
        check(again?.validate().config?.wireguard == full.wireguard,
              "M10 the .conf text reads back to the same WireGuard config")
        if let automatic = standalone("Address = 10.0.0.2/32").config {
            let back = TestConfigFactory.validated(automatic.asConfString()).config
            check(back?.wireguard.interface.mtu == InterfaceDraft.automaticMTU
                    && back?.wireguard.peer.persistentKeepalive == PeerDraft.keepaliveOff,
                  "M11 automatic MTU and keepalive off survive the .conf text")
        } else {
            fail("M11 the automatic row could not be arranged")
        }
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

    // MARK: - D

    func secretlessDetail() async {
        let vectors = [
            ("Alice", "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a",
                      "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"),
            ("Bob", "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb",
                    "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        ]
        for (name, privateHex, publicHex) in vectors {
            let derived = (try? WireGuardKey(parsing: Self.base64(hex: privateHex)))?.derivedPublicKey
            check(derived?.base64 == Self.base64(hex: publicHex),
                  "the public key derived from RFC 7748's \(name) is the RFC's")
        }

        let fixedKey = Data((0..<32).map { UInt8(truncatingIfNeeded: 10 + 7 * $0) }).base64EncodedString()
        guard let key = try? WireGuardKey(parsing: fixedKey),
              var wstunnel = TestConfigFactory.throwaway(name: "TE-Fingerprint", ghost: true)?.wstunnel else {
            fail("the fingerprint rows could not be arranged")
            return
        }
        wstunnel.secret = "probe-secret"
        let fingerprint = wstunnel.secretFingerprint(keyedBy: key)
        check(fingerprint == "b208 b0c2 49d6 5427",
              "the fingerprint equals the HMAC-SHA256 computed outside the app (\(fingerprint ?? "nil"))")
        check(fingerprint?.range(of: "^[0-9a-f]{4}( [0-9a-f]{4}){3}$", options: .regularExpression) != nil,
              "the fingerprint is four groups of four hex digits")
        var other = wstunnel
        other.secret = "probe-secret-2"
        check(other.secretFingerprint(keyedBy: key) != fingerprint, "another secret gives another fingerprint")
        if let otherKey = try? WireGuardKey(parsing: Self.base64(hex: vectors[0].1)) {
            check(wstunnel.secretFingerprint(keyedBy: otherKey) != fingerprint, "another key gives another fingerprint")
        }
        var empty = wstunnel
        empty.secret = ""
        check(empty.secretFingerprint(keyedBy: key) == nil, "an empty secret gives no fingerprint")
        check(fingerprint.map { !$0.contains("probe") } ?? false, "the fingerprint carries none of the secret's text")
    }

    private static func base64(hex: String) -> String {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return Data(bytes).base64EncodedString()
    }
}
#endif
