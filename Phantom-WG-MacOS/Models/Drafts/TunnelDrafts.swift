import Foundation

// MARK: - Field-Level Validation Error

enum FieldValidationError: Equatable {
    case empty
    case wireGuardKey(WireGuardKey.ParseError)
    case address(AddressWithPrefix.ParseError, atIndex: Int)
    case endpoint(IPEndpoint.ParseError)
    case wstunnelURL(WstunnelURL.ParseError)
    case intNotParsed(raw: String)
    case intOutOfRange(value: Int, min: Int, max: Int)
}

// MARK: - Draft Types

struct TunnelDraft: Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    var wireguard: WireguardDraft
    var wstunnel: WstunnelDraft?

    enum Field: Hashable {
        case name
        case interfacePrivateKey
        case interfaceAddresses
        case interfaceDnsServers
        case interfaceMTU
        case interfaceListenPort
        case peerPublicKey
        case peerPresharedKey
        case peerAllowedIPs
        case peerEndpoint
        case peerPersistentKeepalive
        case wstunnelUrl
        case wstunnelSecret
        case wstunnelLocalHost
        case wstunnelLocalPort
        case wstunnelRemoteHost
        case wstunnelRemotePort
    }

    struct ValidationResult {
        let config: TunnelConfig?
        let errors: [Field: FieldValidationError]
    }

    // MARK: Init

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        wireguard: WireguardDraft,
        wstunnel: WstunnelDraft? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.wireguard = wireguard
        self.wstunnel = wstunnel
    }

    // MARK: Validate

    /// @witness ConfigContract.blankWstunnelUrl
    /// @witness ConfigContract.commaOnlyLists
    /// @witness ConfigContract.searchDomainsAndListenPort
    /// @adr 0011
    func validate() -> ValidationResult {
        var errors: [Field: FieldValidationError] = [:]

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { errors[.name] = .empty }

        let (interfaceConfig, interfaceErrors) = wireguard.interface.validate()
        interfaceErrors.forEach { errors[$0.key] = $0.value }

        let (peerConfig, peerErrors) = wireguard.peer.validate(endpointRequired: wstunnel == nil)
        peerErrors.forEach { errors[$0.key] = $0.value }

        let wstunnelConfig: WstunnelConfig?
        if let draft = wstunnel {
            let (cfg, wsErrors) = draft.validate()
            wsErrors.forEach { errors[$0.key] = $0.value }
            wstunnelConfig = cfg
        } else {
            wstunnelConfig = nil
        }

        if wstunnel != nil, wstunnelConfig == nil, errors.isEmpty {
            errors[.wstunnelUrl] = .empty
        }
        if interfaceConfig == nil, errors.isEmpty {
            errors[.interfacePrivateKey] = .empty
        }
        if peerConfig == nil, errors.isEmpty {
            errors[.peerPublicKey] = .empty
        }
        if wstunnel == nil, let peer = peerConfig, peer.endpoint == nil, errors.isEmpty {
            errors[.peerEndpoint] = .empty
        }
        guard
            errors.isEmpty,
            let interfaceConfig,
            let peerConfig
        else {
            return ValidationResult(config: nil, errors: errors)
        }

        let config = TunnelConfig(
            id: id,
            name: trimmedName,
            createdAt: createdAt,
            wireguard: WireguardConfig(interface: interfaceConfig, peer: peerConfig),
            wstunnel: wstunnelConfig
        )
        return ValidationResult(config: config, errors: [:])
    }
}

// MARK: - WireguardDraft

struct WireguardDraft: Equatable {
    var interface: InterfaceDraft
    var peer: PeerDraft
}

// MARK: - InterfaceDraft

struct InterfaceDraft: Equatable {
    static let automaticMTU = 0

    var privateKey: String
    var addresses: String
    var dnsServers: String
    var mtu: String
    var listenPort: String = ""

    func validate() -> (InterfaceConfig?, [TunnelDraft.Field: FieldValidationError]) {
        var errors: [TunnelDraft.Field: FieldValidationError] = [:]

        let privKey: WireGuardKey?
        let trimmedKey = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            errors[.interfacePrivateKey] = .empty
            privKey = nil
        } else {
            do {
                privKey = try WireGuardKey(parsing: trimmedKey)
            } catch {
                if let err = error as? WireGuardKey.ParseError {
                    errors[.interfacePrivateKey] = .wireGuardKey(err)
                }
                privKey = nil
            }
        }

        let parsedAddresses = parseAddresses(addresses, into: &errors, field: .interfaceAddresses)
        let dns = splitDNS(dnsServers)
        let parsedMTU = parseInt(
            mtu, range: 0...65535, default: Self.automaticMTU,
            into: &errors, field: .interfaceMTU
        )
        let trimmedPort = listenPort.trimmingCharacters(in: .whitespaces)
        let parsedPort = trimmedPort.isEmpty
            ? nil
            : parseInt(trimmedPort, range: 0...65535, default: 0, into: &errors, field: .interfaceListenPort)

        guard errors.isEmpty, let privKey, let addrs = parsedAddresses, let mtuValue = parsedMTU else {
            return (nil, errors)
        }

        return (
            InterfaceConfig(
                privateKey: privKey,
                addresses: addrs,
                dnsServers: dns.servers,
                mtu: mtuValue,
                dnsSearch: dns.search,
                listenPort: parsedPort.map { UInt16($0) }
            ),
            [:]
        )
    }
}

// MARK: - PeerDraft

struct PeerDraft: Equatable {
    static let keepaliveOff = 0

    var publicKey: String
    var presharedKey: String
    var allowedIPs: String
    var endpoint: String
    var persistentKeepalive: String

    func validate(endpointRequired: Bool) -> (PeerConfig?, [TunnelDraft.Field: FieldValidationError]) {
        var errors: [TunnelDraft.Field: FieldValidationError] = [:]

        let pubKey = parseRequiredKey(publicKey, field: .peerPublicKey, into: &errors)
        let psk = parseOptionalKey(presharedKey, field: .peerPresharedKey, into: &errors)
        let parsedAllowed = parseAddresses(allowedIPs, into: &errors, field: .peerAllowedIPs)
        let parsedEndpoint = endpointRequired ? parseEndpoint(endpoint, into: &errors) : nil
        let parsedKeepalive = parseInt(
            persistentKeepalive, range: 0...65535, default: Self.keepaliveOff,
            into: &errors, field: .peerPersistentKeepalive
        )

        guard errors.isEmpty,
              let pubKey,
              let allowed = parsedAllowed,
              let keepalive = parsedKeepalive else {
            return (nil, errors)
        }

        return (
            PeerConfig(
                publicKey: pubKey,
                presharedKey: psk,
                allowedIPs: allowed,
                endpoint: parsedEndpoint,
                persistentKeepalive: keepalive
            ),
            [:]
        )
    }

    private func parseRequiredKey(
        _ raw: String,
        field: TunnelDraft.Field,
        into errors: inout [TunnelDraft.Field: FieldValidationError]
    ) -> WireGuardKey? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            errors[field] = .empty
            return nil
        }
        do {
            return try WireGuardKey(parsing: trimmed)
        } catch let err as WireGuardKey.ParseError {
            errors[field] = .wireGuardKey(err)
            return nil
        } catch {
            return nil
        }
    }

    private func parseOptionalKey(
        _ raw: String,
        field: TunnelDraft.Field,
        into errors: inout [TunnelDraft.Field: FieldValidationError]
    ) -> WireGuardKey? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            return try WireGuardKey(parsing: trimmed)
        } catch let err as WireGuardKey.ParseError {
            errors[field] = .wireGuardKey(err)
            return nil
        } catch {
            return nil
        }
    }

    private func parseEndpoint(
        _ raw: String,
        into errors: inout [TunnelDraft.Field: FieldValidationError]
    ) -> IPEndpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            errors[.peerEndpoint] = .empty
            return nil
        }
        do {
            return try IPEndpoint(parsing: trimmed)
        } catch let err as IPEndpoint.ParseError {
            errors[.peerEndpoint] = .endpoint(err)
            return nil
        } catch {
            return nil
        }
    }
}

// MARK: - WstunnelDraft

struct WstunnelDraft: Equatable {
    var url: String
    var secret: String
    var localHost: String
    var localPort: String
    var remoteHost: String
    var remotePort: String

    func validate() -> (WstunnelConfig?, [TunnelDraft.Field: FieldValidationError]) {
        var errors: [TunnelDraft.Field: FieldValidationError] = [:]

        let parsedURL: WstunnelURL?
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty {
            errors[.wstunnelUrl] = .empty
            parsedURL = nil
        } else {
            do {
                parsedURL = try WstunnelURL(parsing: trimmedURL)
            } catch {
                if let err = error as? WstunnelURL.ParseError {
                    errors[.wstunnelUrl] = .wstunnelURL(err)
                }
                parsedURL = nil
            }
        }

        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSecret.isEmpty {
            errors[.wstunnelSecret] = .empty
        }

        let trimmedLocalHost = localHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLocalHost.isEmpty {
            errors[.wstunnelLocalHost] = .empty
        }
        let trimmedRemoteHost = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRemoteHost.isEmpty {
            errors[.wstunnelRemoteHost] = .empty
        }

        let parsedLocalPort = parsePort(localPort, into: &errors, field: .wstunnelLocalPort)
        let parsedRemotePort = parsePort(remotePort, into: &errors, field: .wstunnelRemotePort)

        guard errors.isEmpty,
              let parsedURL,
              let parsedLocalPort,
              let parsedRemotePort else {
            return (nil, errors)
        }

        return (
            WstunnelConfig(
                url: parsedURL,
                secret: trimmedSecret,
                localHost: trimmedLocalHost,
                localPort: parsedLocalPort,
                remoteHost: trimmedRemoteHost,
                remotePort: parsedRemotePort
            ),
            [:]
        )
    }
}

// MARK: - Shared List / Numeric Parsers

private func parseAddresses(
    _ input: String,
    into errors: inout [TunnelDraft.Field: FieldValidationError],
    field: TunnelDraft.Field
) -> [AddressWithPrefix]? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        errors[field] = .empty
        return nil
    }
    let entries = splitList(trimmed)
    if entries.isEmpty {
        errors[field] = .empty
        return nil
    }
    var result: [AddressWithPrefix] = []
    for (index, entry) in entries.enumerated() {
        do {
            let addr = try AddressWithPrefix(parsing: entry)
            result.append(addr)
        } catch {
            if let err = error as? AddressWithPrefix.ParseError {
                errors[field] = .address(err, atIndex: index)
            }
            return nil
        }
    }
    return result
}

private func splitDNS(_ input: String) -> (servers: [IPAddressEntry], search: [String]) {
    var servers: [IPAddressEntry] = []
    var search: [String] = []
    for entry in splitList(input.trimmingCharacters(in: .whitespacesAndNewlines)) {
        if let server = try? IPAddressEntry(parsing: entry) {
            servers.append(server)
        } else {
            search.append(entry)
        }
    }
    return (servers, search)
}

private func parseInt(
    _ input: String,
    range: ClosedRange<Int>,
    default defaultValue: Int,
    into errors: inout [TunnelDraft.Field: FieldValidationError],
    field: TunnelDraft.Field
) -> Int? {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return defaultValue }
    guard let value = Int(trimmed) else {
        errors[field] = .intNotParsed(raw: trimmed)
        return nil
    }
    guard range.contains(value) else {
        errors[field] = .intOutOfRange(value: value, min: range.lowerBound, max: range.upperBound)
        return nil
    }
    return value
}

private func parsePort(
    _ input: String,
    into errors: inout [TunnelDraft.Field: FieldValidationError],
    field: TunnelDraft.Field
) -> UInt16? {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
        errors[field] = .empty
        return nil
    }
    guard let value = Int(trimmed) else {
        errors[field] = .intNotParsed(raw: trimmed)
        return nil
    }
    guard value > 0, value <= 65535 else {
        errors[field] = .intOutOfRange(value: value, min: 1, max: 65535)
        return nil
    }
    return UInt16(value)
}

private func splitList(_ input: String) -> [String] {
    input
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}
