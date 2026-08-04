import Foundation

// MARK: - Tunnel Config

/// Top-level tunnel configuration. All nested fields are pre-validated:
/// once a `TunnelConfig` exists it is guaranteed well-formed.
/// Drafts (`TunnelDraft`) hold raw user-edited strings and are converted
/// into this type via `validate()` before storage.
///
/// `Codable` because the whole value is what gets sealed into the
/// System keychain vault — one payload per tunnel, secrets included.
struct TunnelConfig: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var createdAt: Date
    var wireguard: WireguardConfig
    var wstunnel: WstunnelConfig?

    /// Ghost mode when wstunnel is present, standalone WireGuard otherwise.
    var isGhostMode: Bool { wstunnel != nil }

    /// The secret-free projection stored in `providerConfiguration`.
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

    /// Serializes the config into the `.conf` textual format accepted by
    /// `ConfParser.parse(...)`. Matches what the Copy Config action produces.
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
        lines.append("Address = \(wireguard.interface.addresses.map(\.textual).joined(separator: ", "))")
        lines.append("DNS = \(wireguard.interface.dnsServers.map(\.textual).joined(separator: ", "))")
        lines.append("MTU = \(wireguard.interface.mtu)")
        lines.append("")

        lines.append("[Peer]")
        lines.append("PublicKey = \(wireguard.peer.publicKey.textual)")
        if let psk = wireguard.peer.presharedKey {
            lines.append("PresharedKey = \(psk.textual)")
        }
        lines.append("AllowedIPs = \(wireguard.peer.allowedIPs.map(\.textual).joined(separator: ", "))")
        lines.append("Endpoint = \(wireguard.peer.endpoint.textual)")
        lines.append("PersistentKeepalive = \(wireguard.peer.persistentKeepalive)")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Tunnel Identity

/// What the system's NetworkExtension preferences are allowed to know
/// about a tunnel: enough to list it, sort it, name it and badge it —
/// and nothing that would be worth stealing. The secrets live in the
/// vault the tunnel extension owns, keyed by this `id`.
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

    enum CodingKeys: String, CodingKey {
        case privateKey = "private_key"
        case addresses
        case dnsServers = "dns_servers"
        case mtu
    }
}

struct PeerConfig: Codable, Equatable {
    var publicKey: WireGuardKey
    var presharedKey: WireGuardKey?
    var allowedIPs: [AddressWithPrefix]
    var endpoint: IPEndpoint
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
