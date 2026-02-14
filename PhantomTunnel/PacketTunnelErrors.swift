import os.log
import WireGuardKit

enum PacketTunnelProviderError: String, Error {
    case savedProtocolConfigurationIsInvalid
    case invalidWstunnelConfig
    case couldNotStartWstunnel
    case couldNotStartWireGuard
    case dnsResolutionFailed
}

extension WireGuardLogLevel {
    var osLogLevel: OSLogType {
        switch self {
        case .verbose: return .debug
        case .error: return .error
        }
    }
}

func wg_log(_ type: OSLogType, message: String) {
    TunnelLogger.log(.wireGuard, message)
}
