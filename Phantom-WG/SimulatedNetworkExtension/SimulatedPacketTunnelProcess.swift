#if DEBUG && targetEnvironment(simulator)
import Foundation
import NetworkExtension

/// Stands in for the PhantomTunnel extension process while a simulated
/// session is up. It answers the app's provider messages on the same
/// opcodes and in the same reply shapes as `PacketTunnelProvider`:
/// `0` runtime stats (`TunnelRuntimeStats`), `1` the log ring as JSON,
/// `2` clear the ring, `3` rebuild the layer and answer with a
/// `TunnelResetReply`, a second request joining the one in flight.
///
/// Starting refuses the same saved configurations the extension's
/// `WireGuardConfigBuilder` refuses — no address, no AllowedIPs, a
/// standalone peer without an endpoint — and the session ends with the
/// extension's own sentence for it. Nothing here opens a socket: the
/// stats are derived from the time connected, and the first log line
/// says so.
///
/// Main thread only.
final class SimulatedPacketTunnelProcess {

    private enum Tag: String {
        case tunnel = "TUN"
        case wstunnel = "WS"
        case wireGuard = "WG"
    }

    private struct Entry: Codable {
        let timestamp: String
        let tag: String
        let message: String
    }

    private weak var session: SimulatedSession?
    private var buffer: [Entry] = []
    private var config: TunnelConfig?
    private var connectedAt: Date?
    private var resetWaiters: [(TunnelResetReply) -> Void]?

    init(session: SimulatedSession) {
        self.session = session
    }

    // MARK: - Lifecycle

    func startTunnel(protocolConfiguration: NETunnelProviderProtocol?, completion: @escaping (Error?) -> Void) {
        log(.tunnel, "PacketTunnelProvider starting... (simulated extension: no packets leave this device)")
        guard let config = protocolConfiguration?.tunnelConfig else {
            log(.tunnel, "ERROR: Invalid tunnel configuration")
            after(Self.failDelay) { completion(Self.extensionError(.savedProtocolConfigurationIsInvalid)) }
            return
        }
        log(.tunnel, "Config loaded: \(config.name) (\(config.isGhostMode ? "Ghost" : "WireGuard"))")
        if let wstunnel = config.wstunnel {
            log(.wstunnel, "Starting wstunnel...")
            log(.wstunnel, "Remote: \(wstunnel.url.textual)")
            log(.wstunnel, "Local proxy: \(wstunnel.localHost):\(wstunnel.localPort)")
            log(.wstunnel, "Forward to: \(wstunnel.remoteHost):\(wstunnel.remotePort)")
        }
        log(.wireGuard, "Building WireGuard config...")
        if let refusal = Self.leakGuardRefusal(config) {
            log(.wireGuard, refusal)
            after(Self.failDelay) { completion(Self.extensionError(.savedProtocolConfigurationIsInvalid)) }
            return
        }
        log(.wireGuard, "Starting WireGuard adapter...")
        after(Self.connectDelay) { [weak self] in
            guard let self else { return }
            self.config = config
            self.connectedAt = Date()
            self.log(.tunnel, "Tunnel active")
            completion(nil)
        }
    }

    func stopTunnel(reason: NEProviderStopReason, completion: @escaping () -> Void) {
        log(.tunnel, "Stopping tunnel (reason: \(reason.rawValue))")
        log(.wireGuard, "Stopping WireGuard adapter...")
        after(Self.disconnectDelay) { [weak self] in
            guard let self else { return }
            self.log(.wireGuard, "WireGuard stopped")
            if self.config?.isGhostMode == true {
                self.log(.wstunnel, "Stopping wstunnel...")
                self.log(.wstunnel, "Wstunnel stopped")
            }
            self.log(.tunnel, "Tunnel disconnected")
            self.connectedAt = nil
            completion()
        }
    }

    // MARK: - App Messages

    func handleAppMessage(_ data: Data, completion: @escaping (Data?) -> Void) {
        guard let opcode = data.first else {
            reply(nil, to: completion)
            return
        }
        switch opcode {
        case 0:
            reply(session?.status == .connected ? runtimeStats().encoded() : nil, to: completion)
        case 1:
            reply(try? JSONEncoder().encode(buffer), to: completion)
        case 2:
            buffer.removeAll(keepingCapacity: true)
            reply(Data([2]), to: completion)
        case 3:
            reset { [weak self] outcome in
                self?.reply(Data([3, outcome.rawValue]), to: completion)
            }
        default:
            reply(nil, to: completion)
        }
    }

    // MARK: - Reset

    private func reset(completion: @escaping (TunnelResetReply) -> Void) {
        if resetWaiters != nil {
            log(.tunnel, "Reset — one is already rebuilding this layer, waiting for it")
            resetWaiters?.append(completion)
            return
        }
        guard let config, connectedAt != nil else {
            log(.tunnel, "Reset skipped — no active layer config")
            completion(.skipped)
            return
        }
        resetWaiters = [completion]
        let modeLabel = config.isGhostMode ? "Ghost (wstunnel + WireGuard)" : "Standalone (WireGuard)"
        log(.tunnel, "Reset — restarting layer (\(modeLabel))")
        session?.setReasserting(true)
        log(.wireGuard, "Reset — adapter stopped")
        if config.isGhostMode {
            log(.wstunnel, "Reset — wstunnel stopped")
        }
        after(Self.resetDelay) { [weak self] in
            guard let self else { return }
            if config.isGhostMode {
                self.log(.wstunnel, "Reset — wstunnel restarted")
            }
            self.session?.setReasserting(false)
            self.log(.wireGuard, "Reset — adapter restarted")
            self.log(.tunnel, "Reset complete")
            let waiters = self.resetWaiters ?? []
            self.resetWaiters = nil
            waiters.forEach { $0(.rebuilt) }
        }
    }

    // MARK: - Stats

    private func runtimeStats() -> TunnelRuntimeStats {
        guard let connectedAt else { return TunnelRuntimeStats() }
        let elapsed = Int64(Date().timeIntervalSince(connectedAt))
        let handshake = Int64(connectedAt.timeIntervalSince1970) + elapsed / 120 * 120
        return TunnelRuntimeStats(
            rxBytes: elapsed * 18_432,
            txBytes: elapsed * 6_144,
            lastHandshakeTimestamp: handshake
        )
    }

    // MARK: - Leak Guards

    private static func leakGuardRefusal(_ config: TunnelConfig) -> String? {
        if config.wireguard.interface.addresses.isEmpty {
            return "ERROR: No valid addresses"
        }
        if config.wireguard.peer.allowedIPs.isEmpty {
            return "ERROR: Peer has no usable AllowedIPs — refusing to start (no-route leak guard)"
        }
        if config.wstunnel == nil && config.wireguard.peer.endpoint == nil {
            return "ERROR: Standalone config without endpoint"
        }
        return nil
    }

    private enum ExtensionError: String {
        case savedProtocolConfigurationIsInvalid = "The saved tunnel configuration could not be read."
    }

    private static func extensionError(_ error: ExtensionError) -> NSError {
        NSError(
            domain: "SimulatedNetworkExtension",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: error.rawValue]
        )
    }

    // MARK: - Log Ring

    private static let maxEntries = 2000

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private func log(_ tag: Tag, _ message: String) {
        buffer.append(Entry(timestamp: Self.formatter.string(from: Date()), tag: tag.rawValue, message: message))
        if buffer.count > Self.maxEntries {
            buffer.removeFirst(buffer.count - Self.maxEntries)
        }
    }

    // MARK: - Timing

    private static let connectDelay: TimeInterval = 0.8
    private static let disconnectDelay: TimeInterval = 0.4
    private static let failDelay: TimeInterval = 0.3
    private static let resetDelay: TimeInterval = 0.6
    private static let replyDelay: TimeInterval = 0.02

    private func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reply(_ data: Data?, to completion: @escaping (Data?) -> Void) {
        after(Self.replyDelay) { completion(data) }
    }
}
#endif
