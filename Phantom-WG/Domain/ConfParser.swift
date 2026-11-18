import Foundation

/// Structural parser for WireGuard `.conf` text.
///
/// Produces a `TunnelDraft` populated from `[Wstunnel]` (optional),
/// `[Interface]`, and `[Peer]` sections. The line rules are
/// WireGuardKit's: an inline `#` comment is dropped (kept inside
/// `[Wstunnel]`, whose values may carry `#`), and an unknown section, an
/// unknown key, a line without `=`, and a repeated single-value key are
/// errors. Field-level value validation (keys, addresses, endpoint,
/// integers) is deferred to `TunnelDraft.validate()`.
///
/// Ghost rule: when a `[Wstunnel]` section is present, the peer
/// `Endpoint` is system-defined (the wstunnel listener), so the key
/// becomes optional and is ignored even when written.
///
/// The draft's `name` is left empty; the caller sets it before
/// validation.
enum ConfParser {

    enum ParseError: Error, LocalizedError, Equatable {
        case emptyInput
        case noInterfaceSection
        case noPeerSection
        case duplicateSection(String)
        case missingKey(section: String, key: String)
        case invalidTunnelFormat(section: String, key: String)
        case invalidLine(String)
        case unknownKey(section: String, key: String)
        case duplicateKey(section: String, key: String)
        case invalidValue(section: String, key: String)

        var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "Configuration is empty"
            case .noInterfaceSection:
                return "Missing [Interface] section"
            case .noPeerSection:
                return "Missing [Peer] section"
            case .duplicateSection(let section):
                return "Duplicate [\(section)] section — only one is supported"
            case .missingKey(let section, let key):
                return "[\(section)] missing required key: \(key)"
            case .invalidTunnelFormat(let section, let key):
                return "[\(section)] invalid \(key): expected udp://host:port:host:port"
            case .invalidLine(let line):
                return "Line not understood: \(line)"
            case .unknownKey(let section, let key):
                return "[\(section)] has an unknown key: \(key)"
            case .duplicateKey(let section, let key):
                return "[\(section)] lists \(key) more than once"
            case .invalidValue(let section, let key):
                return "[\(section)] has an invalid \(key)"
            }
        }
    }

    private static let sectionKeys: [String: Set<String>] = [
        "interface": ["privatekey", "listenport", "address", "dns", "mtu"],
        "peer": ["publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive"],
        "wstunnel": ["url", "secret", "tunnel"]
    ]

    // MARK: - Entry Point

    static func parse(_ input: String) throws -> TunnelDraft {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.emptyInput }

        let sections = try splitSections(trimmed)

        guard let interfaceAttrs = sections["interface"] else {
            throw ParseError.noInterfaceSection
        }
        guard let peerAttrs = sections["peer"] else {
            throw ParseError.noPeerSection
        }

        let wstunnelDraft: WstunnelDraft?
        if let wsAttrs = sections["wstunnel"] {
            wstunnelDraft = try parseWstunnel(wsAttrs)
        } else {
            wstunnelDraft = nil
        }

        let interfaceDraft = try parseInterface(interfaceAttrs)
        let peerDraft = try parsePeer(peerAttrs, endpointRequired: wstunnelDraft == nil)

        return TunnelDraft(
            name: "",
            wireguard: WireguardDraft(interface: interfaceDraft, peer: peerDraft),
            wstunnel: wstunnelDraft
        )
    }

    // MARK: - Section Splitting

    /// Collects key/value pairs per `[Section]`. Multi-entry keys
    /// (Address, AllowedIPs, DNS) are merged with comma separators.
    private static func splitSections(_ input: String) throws -> [String: [String: String]] {
        let lines = input.components(separatedBy: .newlines)
        var result: [String: [String: String]] = [:]
        var currentSection: String?
        let multiEntryKeys: Set<String> = ["address", "allowedips", "dns"]

        for line in lines {
            let whole = line.trimmingCharacters(in: .whitespaces)
            let uncommented = whole.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let isHeader = uncommented.hasPrefix("[") && uncommented.hasSuffix("]")
            let stripped = isHeader || currentSection != "wstunnel" ? uncommented : whole
            if stripped.isEmpty || stripped.hasPrefix("#") { continue }

            // Section header
            if stripped.hasPrefix("["), stripped.hasSuffix("]") {
                // Trimmed like every key below, and for the same
                // reason: a stray space inside the brackets —
                // "[Peer ]" — must not mint a DISTINCT section that
                // dodges the duplicate guard while parse() reads only
                // the exact-spelled name, silently dropping the whole
                // peer the variant carried.
                let name = String(stripped.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces).lowercased()
                guard sectionKeys[name] != nil else {
                    throw ParseError.invalidLine(stripped)
                }
                // Each section is a singleton here. A repeated header —
                // most often a second [Peer] — used to merge into the
                // first (last value wins per key), silently collapsing
                // multiple peers into one carrying the wrong key, so
                // traffic for the dropped peer would encrypt to it.
                // Reject the ambiguity instead of resolving it blindly.
                guard result[name] == nil else {
                    throw ParseError.duplicateSection(name.capitalized)
                }
                result[name] = [:]
                currentSection = name
                continue
            }

            // Key = Value
            guard let equalsIndex = stripped.firstIndex(of: "=") else {
                throw ParseError.invalidLine(stripped)
            }
            guard let section = currentSection else { continue }

            let keyWithCase = stripped[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let key = keyWithCase.lowercased()
            let value = stripped[stripped.index(equalsIndex, offsetBy: 1)...]
                .trimmingCharacters(in: .whitespaces)

            guard sectionKeys[section]?.contains(key) == true else {
                throw ParseError.unknownKey(section: section.capitalized, key: keyWithCase)
            }
            if let existing = result[section]?[key] {
                guard multiEntryKeys.contains(key) else {
                    throw ParseError.duplicateKey(section: section.capitalized, key: keyWithCase)
                }
                result[section]?[key] = existing + ", " + value
            } else {
                result[section]?[key] = value
            }
        }

        return result
    }

    // MARK: - Wstunnel

    private static func parseWstunnel(_ attrs: [String: String]) throws -> WstunnelDraft {
        guard let url = attrs["url"], !url.isEmpty else {
            throw ParseError.missingKey(section: "Wstunnel", key: "Url")
        }
        guard let secret = attrs["secret"], !secret.isEmpty else {
            throw ParseError.missingKey(section: "Wstunnel", key: "Secret")
        }
        guard let tunnel = attrs["tunnel"], !tunnel.isEmpty else {
            throw ParseError.missingKey(section: "Wstunnel", key: "Tunnel")
        }

        // udp://127.0.0.1:51820:127.0.0.1:51820
        var raw = tunnel
        if raw.lowercased().hasPrefix("udp://") { raw = String(raw.dropFirst(6)) }

        let parts = raw.split(separator: ":", maxSplits: 3).map(String.init)
        guard parts.count == 4 else {
            throw ParseError.invalidTunnelFormat(section: "Wstunnel", key: "Tunnel")
        }

        return WstunnelDraft(
            url: url,
            secret: secret,
            localHost: parts[0],
            localPort: parts[1],
            remoteHost: parts[2],
            remotePort: parts[3]
        )
    }

    // MARK: - Interface

    private static func parseInterface(_ attrs: [String: String]) throws -> InterfaceDraft {
        guard let privateKey = attrs["privatekey"], !privateKey.isEmpty else {
            throw ParseError.missingKey(section: "Interface", key: "PrivateKey")
        }
        guard let address = attrs["address"], !address.isEmpty else {
            throw ParseError.missingKey(section: "Interface", key: "Address")
        }
        if let listenPort = attrs["listenport"], UInt16(listenPort) == nil {
            throw ParseError.invalidValue(section: "Interface", key: "ListenPort")
        }

        return InterfaceDraft(
            privateKey: privateKey,
            addresses: address,
            dnsServers: attrs["dns"] ?? "",
            mtu: attrs["mtu"] ?? ""
        )
    }

    // MARK: - Peer

    private static func parsePeer(_ attrs: [String: String], endpointRequired: Bool) throws -> PeerDraft {
        guard let publicKey = attrs["publickey"], !publicKey.isEmpty else {
            throw ParseError.missingKey(section: "Peer", key: "PublicKey")
        }

        // Ghost configs never carry the user's Endpoint into the
        // draft — the system defines it from the wstunnel listener.
        let endpoint: String
        if endpointRequired {
            guard let value = attrs["endpoint"], !value.isEmpty else {
                throw ParseError.missingKey(section: "Peer", key: "Endpoint")
            }
            endpoint = value
        } else {
            endpoint = ""
        }

        return PeerDraft(
            publicKey: publicKey,
            presharedKey: attrs["presharedkey"] ?? "",
            allowedIPs: attrs["allowedips"] ?? "0.0.0.0/0, ::/0",
            endpoint: endpoint,
            persistentKeepalive: attrs["persistentkeepalive"] ?? ""
        )
    }
}
