import Foundation

enum ConfParser {

    enum ParseError: Error, LocalizedError, Equatable {
        case emptyInput
        case noInterfaceSection
        case noPeerSection
        case duplicateSection(String)
        case missingKey(section: String, key: String)
        case invalidTunnelFormat(section: String, key: String)

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
            }
        }
    }

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
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped.hasPrefix("#") { continue }

            if stripped.hasPrefix("["), stripped.hasSuffix("]") {
                let name = String(stripped.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces).lowercased()
                guard result[name] == nil else {
                    throw ParseError.duplicateSection(name.capitalized)
                }
                result[name] = [:]
                currentSection = name
                continue
            }

            guard let section = currentSection,
                  let equalsIndex = stripped.firstIndex(of: "=") else { continue }

            let key = stripped[..<equalsIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = stripped[stripped.index(equalsIndex, offsetBy: 1)...]
                .trimmingCharacters(in: .whitespaces)

            if multiEntryKeys.contains(key), let existing = result[section]?[key] {
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
            dnsServers: attrs["dns"] ?? "1.1.1.1, 9.9.9.9",
            mtu: attrs["mtu"] ?? "1420"
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
            persistentKeepalive: attrs["persistentkeepalive"] ?? "25"
        )
    }
}
