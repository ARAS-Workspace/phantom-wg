import Foundation

enum PacketTunnelProviderError: String, Error, LocalizedError {
    case savedProtocolConfigurationIsInvalid
    case invalidWstunnelConfig
    case couldNotStartWstunnel
    case couldNotStartWireGuard

    /// Read back by the app through the system's disconnect record
    /// when `startTunnel` throws — keep these human-readable, or the
    /// user sees "(PacketTunnelProviderError error N.)" instead.
    var errorDescription: String? {
        switch self {
        case .savedProtocolConfigurationIsInvalid:
            return "The saved tunnel configuration could not be read."
        case .invalidWstunnelConfig:
            return "The wstunnel configuration is invalid."
        case .couldNotStartWstunnel:
            return "The wstunnel proxy could not be started."
        case .couldNotStartWireGuard:
            return "WireGuard could not be started."
        }
    }
}

/// WireGuard adapter log sink. Severity is deliberately flattened —
/// the ring buffer stores plain tagged lines only.
func wg_log(message: String) {
    TunnelLogger.log(.wireGuard, message)
}
