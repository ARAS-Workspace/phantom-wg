import Foundation

enum PacketTunnelProviderError: String, Error, LocalizedError {
    case savedProtocolConfigurationIsInvalid
    case invalidWstunnelConfig
    case couldNotStartWstunnel
    case couldNotStartWireGuard

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

func wg_log(message: String) {
    TunnelLogger.log(.wireGuard, message)
}
