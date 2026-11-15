import Foundation

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
            }
        }
    }

    private static let sectionKeys: [String: Set<String>] = [
        "interface": ["privatekey", "listenport", "address", "dns", "mtu"],
        "peer": ["publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive"],
        "wstunnel": ["url", "secret", "tunnel"],
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

            if stripped.hasPrefix("["), stripped.hasSuffix("]") {
                let name = String(stripped.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces).lowercased()
                guard sectionKeys[name] != nil else {
                    throw ParseError.invalidLine(stripped)
                }
                guard result[name] == nil else {
                    throw ParseError.duplicateSection(name.capitalized)
                }
                result[name] = [:]
                currentSection = name
                continue
            }

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

        return InterfaceDraft(
            privateKey: privateKey,
            addresses: address,
            dnsServers: attrs["dns"] ?? "",
            mtu: attrs["mtu"] ?? "",
            listenPort: attrs["listenport"] ?? ""
        )
    }

    // MARK: - Peer

    private static func parsePeer(_ attrs: [String: String], endpointRequired: Bool) throws -> PeerDraft {
        guard let publicKey = attrs["publickey"], !publicKey.isEmpty else {
            throw ParseError.missingKey(section: "Peer", key: "PublicKey")
        }

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
