import os.log
import WireGuardKit

enum PacketTunnelProviderError: String, Error {
    case savedProtocolConfigurationIsInvalid
    case couldNotStartWstunnel
    case couldNotStartWireGuard
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
    SharedLogger.log(.wireGuard, message)
}
