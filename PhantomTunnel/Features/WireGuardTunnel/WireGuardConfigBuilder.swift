import Foundation
import Network
import WireGuardKit

enum WireGuardConfigBuilder {

    /// Converts `WireguardConfig` + optional `WstunnelConfig` into
    /// WireGuardKit's `TunnelConfiguration`. Inputs normally come out
    /// of the validated model, but the extension decodes them straight
    /// from the vault payload — so this builder re-checks what
    /// WireGuardKit cannot represent and throws instead of trusting
    /// the payload.
    ///
    /// - Ghost mode: endpoint is system-defined as the wstunnel
    ///   listener (`localHost:localPort`); a user endpoint is never
    ///   consulted
    /// - Standalone: endpoint used verbatim from peer config
    static func build(wireguard: WireguardConfig, wstunnel: WstunnelConfig?) throws -> TunnelConfiguration {
        let interfaceConfig = try buildInterface(from: wireguard)
        let peerConfig = try buildPeer(from: wireguard, wstunnel: wstunnel)

        return TunnelConfiguration(
            name: nil,
            interface: interfaceConfig,
            peers: [peerConfig]
        )
    }

    // MARK: - Private

    private static func buildInterface(from config: WireguardConfig) throws -> InterfaceConfiguration {
        guard let privateKey = PrivateKey(base64Key: config.interface.privateKey.textual) else {
            TunnelLogger.log(.wireGuard, "ERROR: Invalid private key")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }

        var iface = InterfaceConfiguration(privateKey: privateKey)

        iface.addresses = config.interface.addresses.compactMap {
            IPAddressRange(from: $0.textual)
        }

        guard !iface.addresses.isEmpty else {
            TunnelLogger.log(.wireGuard, "ERROR: No valid addresses")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }

        TunnelLogger.log(.wireGuard, "Interface addresses: \(iface.addresses.map { $0.stringRepresentation })")

        iface.dns = config.interface.dnsServers.compactMap {
            DNSServer(from: $0.textual)
        }

        if config.interface.mtu > 0 {
            iface.mtu = UInt16(clamping: config.interface.mtu)
        }

        return iface
    }

    private static func buildPeer(from config: WireguardConfig, wstunnel: WstunnelConfig?) throws -> PeerConfiguration {
        guard let publicKey = PublicKey(base64Key: config.peer.publicKey.textual) else {
            TunnelLogger.log(.wireGuard, "ERROR: Invalid public key")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }

        var peer = PeerConfiguration(publicKey: publicKey)

        if let psk = config.peer.presharedKey,
           let preSharedKey = PreSharedKey(base64Key: psk.textual) {
            peer.preSharedKey = preSharedKey
        }

        peer.allowedIPs = config.peer.allowedIPs.compactMap {
            IPAddressRange(from: $0.textual)
        }

        TunnelLogger.log(.wireGuard, "AllowedIPs: \(peer.allowedIPs.count) entries")

        // Endpoint: Ghost mode -> wstunnel listener (system-defined),
        // standalone -> the peer's own endpoint. A standalone config
        // without one can only be a hand-damaged payload — refuse to start.
        let endpointString: String
        if let ws = wstunnel {
            endpointString = "\(ws.localHost):\(ws.localPort)"
            TunnelLogger.log(.wireGuard, "Endpoint (Ghost): \(endpointString)")
        } else if let peerEndpoint = config.peer.endpoint {
            endpointString = peerEndpoint.textual
            TunnelLogger.log(.wireGuard, "Endpoint (standalone): \(endpointString)")
        } else {
            TunnelLogger.log(.wireGuard, "ERROR: Standalone config without endpoint")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }

        guard let endpoint = Endpoint(from: endpointString) else {
            TunnelLogger.log(.wireGuard, "ERROR: Invalid endpoint: \(endpointString)")
            throw PacketTunnelProviderError.savedProtocolConfigurationIsInvalid
        }
        peer.endpoint = endpoint

        if config.peer.persistentKeepalive > 0 {
            peer.persistentKeepAlive = UInt16(clamping: config.peer.persistentKeepalive)
        }

        return peer
    }
}
