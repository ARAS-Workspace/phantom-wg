import Foundation

// MARK: - Tunnel Config

struct TunnelConfig: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var createdAt: Date
    var wireguard: WireguardConfig
    var wstunnel: WstunnelConfig?

    var isGhostMode: Bool { wstunnel != nil }

    var identity: TunnelIdentity {
        TunnelIdentity(id: id, name: name, createdAt: createdAt, isGhost: isGhostMode)
    }

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        wireguard: WireguardConfig,
        wstunnel: WstunnelConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.wireguard = wireguard
        self.wstunnel = wstunnel
    }

    // MARK: - Serialization

    func asConfString() -> String {
        var lines: [String] = []

        if let ws = wstunnel {
            lines.append("[Wstunnel]")
            lines.append("Url = \(ws.url.textual)")
            lines.append("Secret = \(ws.secret)")
            lines.append("Tunnel = udp://\(ws.localHost):\(ws.localPort):\(ws.remoteHost):\(ws.remotePort)")
            lines.append("")
        }

        lines.append("[Interface]")
        lines.append("PrivateKey = \(wireguard.interface.privateKey.textual)")
        if let listenPort = wireguard.interface.listenPort {
            lines.append("ListenPort = \(listenPort)")
        }
        lines.append("Address = \(wireguard.interface.addresses.map(\.textual).joined(separator: ", "))")
        let dns = wireguard.interface.dnsServers.map(\.textual) + wireguard.interface.dnsSearch
        if !dns.isEmpty {
            lines.append("DNS = \(dns.joined(separator: ", "))")
        }
        lines.append("MTU = \(wireguard.interface.mtu)")
        lines.append("")

        lines.append("[Peer]")
        lines.append("PublicKey = \(wireguard.peer.publicKey.textual)")
        if let psk = wireguard.peer.presharedKey {
            lines.append("PresharedKey = \(psk.textual)")
        }
        lines.append("AllowedIPs = \(wireguard.peer.allowedIPs.map(\.textual).joined(separator: ", "))")
        if wstunnel == nil, let endpoint = wireguard.peer.endpoint {
            lines.append("Endpoint = \(endpoint.textual)")
        }
        lines.append("PersistentKeepalive = \(wireguard.peer.persistentKeepalive)")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Tunnel Identity

struct TunnelIdentity: Equatable {
    let id: UUID
    let name: String
    let createdAt: Date
    let isGhost: Bool
}

// MARK: - WireGuard Config

struct WireguardConfig: Codable, Equatable {
    var interface: InterfaceConfig
    var peer: PeerConfig
}

struct InterfaceConfig: Codable, Equatable {
    var privateKey: WireGuardKey
    var addresses: [AddressWithPrefix]
    var dnsServers: [IPAddressEntry]
    var mtu: Int
    var dnsSearch: [String] = []
    var listenPort: UInt16?

    enum CodingKeys: String, CodingKey {
        case privateKey = "private_key"
        case addresses
        case dnsServers = "dns_servers"
        case mtu
        case dnsSearch = "dns_search"
        case listenPort = "listen_port"
    }
}

extension InterfaceConfig {
    /// @witness ConfigContract.searchDomainsAndListenPort
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        privateKey = try container.decode(WireGuardKey.self, forKey: .privateKey)
        addresses = try container.decode([AddressWithPrefix].self, forKey: .addresses)
        dnsServers = try container.decode([IPAddressEntry].self, forKey: .dnsServers)
        mtu = try container.decode(Int.self, forKey: .mtu)
        dnsSearch = try container.decodeIfPresent([String].self, forKey: .dnsSearch) ?? []
        listenPort = try container.decodeIfPresent(UInt16.self, forKey: .listenPort)
    }
}

struct PeerConfig: Codable, Equatable {
    var publicKey: WireGuardKey
    var presharedKey: WireGuardKey?
    var allowedIPs: [AddressWithPrefix]
    var endpoint: IPEndpoint?
    var persistentKeepalive: Int

    enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
        case presharedKey = "preshared_key"
        case allowedIPs = "allowed_ips"
        case endpoint
        case persistentKeepalive = "persistent_keepalive"
    }
}

// MARK: - Wstunnel Config

struct WstunnelConfig: Codable, Equatable {
    var url: WstunnelURL
    var secret: String
    var localHost: String
    var localPort: UInt16
    var remoteHost: String
    var remotePort: UInt16

    enum CodingKeys: String, CodingKey {
        case url, secret
        case localHost = "local_host"
        case localPort = "local_port"
        case remoteHost = "remote_host"
        case remotePort = "remote_port"
    }
}
