import Foundation

// MARK: - Field-Level Validation Error

/// Typed description of a single-field validation failure. The UI layer
/// maps each case to a localized message; keeping the error as typed data
/// here makes testing deterministic and keeps localization concerns in
/// one place (the view).
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

/// String-backed staging value between the raw `.conf` text and the
/// typed configuration: `ConfParser` fills one from parsed text, and
/// `validate()` turns it into a `TunnelConfig` plus a per-field error
/// map for the banner. Both raw-text surfaces — import and
/// `TunnelEditView` — and the file import (`TunnelBulkImport`) run
/// through it.
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

    init(from config: TunnelConfig) {
        self.id = config.id
        self.name = config.name
        self.createdAt = config.createdAt
        self.wireguard = WireguardDraft(from: config.wireguard)
        self.wstunnel = config.wstunnel.map(WstunnelDraft.init(from:))
    }

    // MARK: Validate

    /// @witness ConfigContract.leakGuardsAndBelts
    /// @witness ConfigContract.searchDomainsAndListenPort
    func validate() -> ValidationResult {
        var errors: [Field: FieldValidationError] = [:]

        // Name
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { errors[.name] = .empty }

        // Interface + peer
        let (interfaceConfig, interfaceErrors) = wireguard.interface.validate()
        interfaceErrors.forEach { errors[$0.key] = $0.value }

        // The endpoint is user data only for standalone configs; in
        // Ghost mode the system defines it from the wstunnel listener.
        let (peerConfig, peerErrors) = wireguard.peer.validate(endpointRequired: wstunnel == nil)
        peerErrors.forEach { errors[$0.key] = $0.value }

        // Wstunnel (optional)
        let wstunnelConfig: WstunnelConfig?
        if let draft = wstunnel {
            let (cfg, wsErrors) = draft.validate()
            wsErrors.forEach { errors[$0.key] = $0.value }
            wstunnelConfig = cfg
        } else {
            wstunnelConfig = nil
        }

        // Every arm that builds nothing records an error today. These
        // belts put a slip that forgets one onto the arm's defining
        // field, so the editor names it: a nil half with an empty error
        // map would otherwise end as a Save that does nothing, and a
        // standalone peer with no endpoint would save and fail only at
        // activation.
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

    init(interface: InterfaceDraft, peer: PeerDraft) {
        self.interface = interface
        self.peer = peer
    }

    init(from config: WireguardConfig) {
        self.interface = InterfaceDraft(from: config.interface)
        self.peer = PeerDraft(from: config.peer)
    }
}

// MARK: - InterfaceDraft

struct InterfaceDraft: Equatable {
    /// WireGuardKit's empty MTU: no value, the system picks it.
    static let automaticMTU = 0

    var privateKey: String
    var addresses: String      // comma-separated
    var dnsServers: String     // comma-separated servers, then search domains
    var mtu: String            // raw text; range-checked in validate()
    var listenPort: String     // raw text; empty → no listen port

    init(privateKey: String, addresses: String, dnsServers: String, mtu: String, listenPort: String = "") {
        self.privateKey = privateKey
        self.addresses = addresses
        self.dnsServers = dnsServers
        self.mtu = mtu
        self.listenPort = listenPort
    }

    init(from config: InterfaceConfig) {
        self.privateKey = config.privateKey.textual
        self.addresses = config.addresses.map(\.textual).joined(separator: ", ")
        self.dnsServers = (config.dnsServers.map(\.textual) + config.dnsSearch).joined(separator: ", ")
        self.mtu = String(config.mtu)
        self.listenPort = config.listenPort.map(String.init) ?? ""
    }

    /// Returns (parsed config or nil) + per-field errors.
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
    /// WireGuardKit's empty keepalive: no value, no keepalive.
    static let keepaliveOff = 0

    var publicKey: String
    var presharedKey: String     // empty → nil
    var allowedIPs: String       // comma-separated
    var endpoint: String
    var persistentKeepalive: String

    init(
        publicKey: String,
        presharedKey: String,
        allowedIPs: String,
        endpoint: String,
        persistentKeepalive: String
    ) {
        self.publicKey = publicKey
        self.presharedKey = presharedKey
        self.allowedIPs = allowedIPs
        self.endpoint = endpoint
        self.persistentKeepalive = persistentKeepalive
    }

    init(from config: PeerConfig) {
        self.publicKey = config.publicKey.textual
        self.presharedKey = config.presharedKey?.textual ?? ""
        self.allowedIPs = config.allowedIPs.map(\.textual).joined(separator: ", ")
        self.endpoint = config.endpoint?.textual ?? ""
        self.persistentKeepalive = String(config.persistentKeepalive)
    }

    func validate(endpointRequired: Bool) -> (PeerConfig?, [TunnelDraft.Field: FieldValidationError]) {
        var errors: [TunnelDraft.Field: FieldValidationError] = [:]

        let pubKey = parseRequiredKey(publicKey, field: .peerPublicKey, into: &errors)
        let psk = parseOptionalKey(presharedKey, field: .peerPresharedKey, into: &errors)
        let parsedAllowed = parseAddresses(allowedIPs, into: &errors, field: .peerAllowedIPs)
        // Ghost rule: whatever the user typed as Endpoint is not
        // carried — the system builds it from the wstunnel listener.
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

    init(
        url: String,
        secret: String,
        localHost: String,
        localPort: String,
        remoteHost: String,
        remotePort: String
    ) {
        self.url = url
        self.secret = secret
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    init(from config: WstunnelConfig) {
        self.url = config.url.textual
        self.secret = config.secret
        self.localHost = config.localHost
        self.localPort = String(config.localPort)
        self.remoteHost = config.remoteHost
        self.remotePort = String(config.remotePort)
    }

    func validate() -> (WstunnelConfig?, [TunnelDraft.Field: FieldValidationError]) {
        var errors: [TunnelDraft.Field: FieldValidationError] = [:]

        // URL
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

        // Secret
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSecret.isEmpty {
            errors[.wstunnelSecret] = .empty
        }

        // Hosts (simple non-empty checks — IP parsing is flexible here
        // because wstunnel accepts both IPs and hostnames for forwarding).
        let trimmedLocalHost = localHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLocalHost.isEmpty {
            errors[.wstunnelLocalHost] = .empty
        }
        let trimmedRemoteHost = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRemoteHost.isEmpty {
            errors[.wstunnelRemoteHost] = .empty
        }

        // Ports
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
    // A comma-only list splits to nothing; it is as empty as a blank one.
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

/// WireGuardKit's DNS rule: an entry that parses as an IP is a server,
/// any other entry is a search domain.
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
