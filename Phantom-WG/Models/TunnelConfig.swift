import Foundation

struct TunnelConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var v: Int
    var name: String
    var wstunnel: WstunnelConfig
    var interface: InterfaceConfig
    var peer: PeerConfig

    enum CodingKeys: String, CodingKey {
        case id, v, name, wstunnel, interface, peer
    }

    init(id: UUID = UUID(), v: Int = 1, name: String, wstunnel: WstunnelConfig, interface: InterfaceConfig, peer: PeerConfig) {
        self.id = id
        self.v = v
        self.name = name
        self.wstunnel = wstunnel
        self.interface = interface
        self.peer = peer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        v = try container.decodeIfPresent(Int.self, forKey: .v) ?? 1
        name = try container.decode(String.self, forKey: .name)
        wstunnel = try container.decode(WstunnelConfig.self, forKey: .wstunnel)
        interface = try container.decode(InterfaceConfig.self, forKey: .interface)
        peer = try container.decode(PeerConfig.self, forKey: .peer)
    }

    static func empty() -> TunnelConfig {
        TunnelConfig(
            name: "",
            wstunnel: WstunnelConfig(url: "", secret: "", localPort: 51820, remoteHost: "127.0.0.1", remotePort: 51820),
            interface: InterfaceConfig(privateKey: "", address: "", dns: "1.1.1.1, 9.9.9.9", mtu: 1280),
            peer: PeerConfig(publicKey: "", allowedIPs: "0.0.0.0/0, ::/0", endpoint: "127.0.0.1:51820", persistentKeepalive: 25)
        )
    }
}

struct WstunnelConfig: Codable, Equatable {
    var url: String
    var secret: String
    var localPort: UInt16
    var remoteHost: String
    var remotePort: UInt16

    enum CodingKeys: String, CodingKey {
        case url, secret
        case localPort = "local_port"
        case remoteHost = "remote_host"
        case remotePort = "remote_port"
    }
}

struct InterfaceConfig: Codable, Equatable {
    var privateKey: String
    var address: String
    var dns: String
    var mtu: Int

    enum CodingKeys: String, CodingKey {
        case privateKey = "private_key"
        case address, dns, mtu
    }
}

struct PeerConfig: Codable, Equatable {
    var publicKey: String
    var presharedKey: String?
    var allowedIPs: String
    var endpoint: String
    var persistentKeepalive: Int

    enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
        case presharedKey = "preshared_key"
        case allowedIPs = "allowed_ips"
        case endpoint
        case persistentKeepalive = "persistent_keepalive"
    }
}
