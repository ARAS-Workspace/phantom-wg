import Foundation
import Network
import WireGuardKit

enum WireGuardConfigBuilder {

    /// Converts a TunnelConfig into WireGuardKit's TunnelConfiguration.
    /// - Filters to IPv4-only addresses and AllowedIPs
    /// - Overrides endpoint to 127.0.0.1:localPort (wstunnel proxy)
    static func build(from config: TunnelConfig) throws -> TunnelConfiguration {
        let interfaceConfig = try buildInterface(from: config)
        let peerConfig = try buildPeer(from: config)

        return TunnelConfiguration(
            name: config.name,
            interface: interfaceConfig,
            peers: [peerConfig]
        )
    }

    // MARK: - Private

    private static func buildInterface(from config: TunnelConfig) throws -> InterfaceConfiguration {
        guard let privateKey = PrivateKey(base64Key: config.interface.privateKey) else {
            TunnelLogger.log(.wireGuard, "ERROR: Invalid private key")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }

        var iface = InterfaceConfiguration(privateKey: privateKey)

        let allAddresses = config.interface.address
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { IPAddressRange(from: $0) }

        iface.addresses = allAddresses.filter { $0.address is IPv4Address }

        if allAddresses.count != iface.addresses.count {
            TunnelLogger.log(.wireGuard, "Filtered \(allAddresses.count - iface.addresses.count) non-IPv4 addresses")
        }

        guard !iface.addresses.isEmpty else {
            TunnelLogger.log(.wireGuard, "ERROR: No valid IPv4 addresses after filtering")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }

        TunnelLogger.log(.wireGuard, "Interface addresses: \(iface.addresses.map { $0.stringRepresentation })")

        iface.dns = config.interface.dns
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { DNSServer(from: $0) }

        if config.interface.mtu > 0 {
            iface.mtu = UInt16(clamping: config.interface.mtu)
        }

        return iface
    }

    private static func buildPeer(from config: TunnelConfig) throws -> PeerConfiguration {
        guard let publicKey = PublicKey(base64Key: config.peer.publicKey) else {
            TunnelLogger.log(.wireGuard, "ERROR: Invalid public key")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }

        var peer = PeerConfiguration(publicKey: publicKey)

        if let psk = config.peer.presharedKey, !psk.isEmpty,
           let preSharedKey = PreSharedKey(base64Key: psk) {
            peer.preSharedKey = preSharedKey
        }

        let allAllowedIPs = config.peer.allowedIPs
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { IPAddressRange(from: $0) }

        peer.allowedIPs = allAllowedIPs.filter { $0.address is IPv4Address }

        if allAllowedIPs.count != peer.allowedIPs.count {
            TunnelLogger.log(.wireGuard, "Filtered \(allAllowedIPs.count - peer.allowedIPs.count) non-IPv4 AllowedIPs")
        }

        TunnelLogger.log(.wireGuard, "AllowedIPs: \(peer.allowedIPs.count) entries")

        let wstunnelEndpoint = "127.0.0.1:\(config.wstunnel.localPort)"
        guard let endpoint = Endpoint(from: wstunnelEndpoint) else {
            TunnelLogger.log(.wireGuard, "ERROR: Invalid endpoint: \(wstunnelEndpoint)")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }
        peer.endpoint = endpoint
        TunnelLogger.log(.wireGuard, "Endpoint override: \(wstunnelEndpoint)")

        if config.peer.persistentKeepalive > 0 {
            peer.persistentKeepAlive = UInt16(clamping: config.peer.persistentKeepalive)
        }

        return peer
    }
}
