import Foundation

// MARK: - Tunnel Config

/// Top-level tunnel configuration. All nested fields are pre-validated:
/// once a `TunnelConfig` exists it is guaranteed well-formed.
/// Drafts (`TunnelDraft`) hold raw user-edited strings and are converted
/// into this type via `.validate()` before storage.
///
/// Persisted as a single JSON blob inside the Keychain (via the
/// `NETunnelProviderProtocol+Keychain` extension); only a persistent
/// reference to that blob lives in `providerConfiguration`.
struct TunnelConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var wireguard: WireguardConfig
    var wstunnel: WstunnelConfig?

    /// Ghost mode when wstunnel is present, standalone WireGuard otherwise.
    var isGhostMode: Bool { wstunnel != nil }

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
        case wireguard, wstunnel
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

    /// Defensive decoder — `createdAt` may be absent in legacy blobs
    /// written before the typed refactor. Missing timestamps fall back
    /// to "now" so the tunnel still loads and sorts somewhere sensible.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        self.wireguard = try container.decode(WireguardConfig.self, forKey: .wireguard)
        self.wstunnel = try container.decodeIfPresent(WstunnelConfig.self, forKey: .wstunnel)
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
        // Ghost rule: the endpoint is system-defined from the wstunnel
        // listener, so it is never serialized next to a [Wstunnel]
        // section — not even when a legacy config still carries one.
        if wstunnel == nil, let endpoint = wireguard.peer.endpoint {
            lines.append("Endpoint = \(endpoint.textual)")
        }
        lines.append("PersistentKeepalive = \(wireguard.peer.persistentKeepalive)")

        return lines.joined(separator: "\n")
    }
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
    /// Absent in Ghost mode: with a wstunnel bridge in front, the
    /// WireGuard endpoint is system-defined as the bridge's local
    /// listener (`localHost:localPort`) and is never user data.
    /// Legacy blobs that still carry one decode fine; the value is
    /// simply not consulted while a `[Wstunnel]` section exists.
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
