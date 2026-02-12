import Foundation
import Network
import WireGuardKit

enum WireGuardConfigBuilder {

    /// Converts a TunnelConfig into WireGuardKit's TunnelConfiguration.
    /// - Filters to IPv4-only addresses and AllowedIPs
    /// - Overrides endpoint to 127.0.0.1:localPort (wstunnel proxy)
    static func build(from config: TunnelConfig) throws -> TunnelConfiguration {
        // --- Interface (IPv4 only) ---
        guard let privateKey = PrivateKey(base64Key: config.interface.privateKey) else {
            SharedLogger.log(.wireGuard, "ERROR: Invalid private key")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }

        var interfaceConfig = InterfaceConfiguration(privateKey: privateKey)

        interfaceConfig.addresses = config.interface.address
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { IPAddressRange(from: $0) }
            .filter { $0.address is IPv4Address }

        SharedLogger.log(.wireGuard, "Interface addresses (IPv4 only): \(interfaceConfig.addresses.map { $0.stringRepresentation })")

        interfaceConfig.dns = config.interface.dns
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { DNSServer(from: $0) }

        if config.interface.mtu > 0 {
            interfaceConfig.mtu = UInt16(clamping: config.interface.mtu)
        }

        // --- Peer ---
        guard let publicKey = PublicKey(base64Key: config.peer.publicKey) else {
            SharedLogger.log(.wireGuard, "ERROR: Invalid public key")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }

        var peerConfig = PeerConfiguration(publicKey: publicKey)

        if let psk = config.peer.presharedKey, !psk.isEmpty,
           let preSharedKey = PreSharedKey(base64Key: psk) {
            peerConfig.preSharedKey = preSharedKey
        }

        peerConfig.allowedIPs = config.peer.allowedIPs
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { IPAddressRange(from: $0) }
            .filter { $0.address is IPv4Address }

        SharedLogger.log(.wireGuard, "AllowedIPs (IPv4 only): \(peerConfig.allowedIPs.count) entries")

        // CRITICAL: Override endpoint to local wstunnel proxy
        let wstunnelEndpoint = "127.0.0.1:\(config.wstunnel.localPort)"
        guard let endpoint = Endpoint(from: wstunnelEndpoint) else {
            SharedLogger.log(.wireGuard, "ERROR: Invalid endpoint: \(wstunnelEndpoint)")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }
        peerConfig.endpoint = endpoint
        SharedLogger.log(.wireGuard, "Endpoint override: \(wstunnelEndpoint)")

        if config.peer.persistentKeepalive > 0 {
            peerConfig.persistentKeepAlive = UInt16(clamping: config.peer.persistentKeepalive)
        }

        return TunnelConfiguration(
            name: config.name,
            interface: interfaceConfig,
            peers: [peerConfig]
        )
    }
}
