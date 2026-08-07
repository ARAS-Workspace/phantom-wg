enum PacketTunnelProviderError: String, Error {
    case savedProtocolConfigurationIsInvalid
    case invalidWstunnelConfig
    case couldNotStartWstunnel
    case couldNotStartWireGuard
}

/// WireGuard adapter log sink. Severity is deliberately flattened —
/// the ring buffer stores plain tagged lines only.
func wg_log(message: String) {
    TunnelLogger.log(.wireGuard, message)
}
