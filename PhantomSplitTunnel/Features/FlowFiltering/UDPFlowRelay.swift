import Network
import NetworkExtension

/// One UDP flow can send datagrams to many destinations from a single
/// socket (DNS, QUIC, game servers, …), so we maintain a per-endpoint
/// `NWConnection` cache. A cached connection lives until it fails or is
/// cancelled — the next datagram to that endpoint rebuilds it — and when
/// the flow closes, every cached connection is cancelled.
///
/// Tangle with the NetworkExtension vs. Network `NWEndpoint` types:
/// the flow callbacks vend the older `NetworkExtension.NWEndpoint`
/// (a.k.a. `NWHostEndpoint`), while `NWConnection` consumes the
/// `Network.NWEndpoint` struct. We bridge at the boundary.
final class UDPFlowRelay {

    private let flow: NEAppProxyUDPFlow
    private let interface: NWInterface
    private let appName: String
    private let relayID = UUID()
    private weak var registry: ActiveFlowRelayRegistry?
    private var connections: [Network.NWEndpoint: NWConnection] = [:]
    private var closed = false
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "phantom-split.udp-relay", qos: .utility)

    /// See TCPFlowRelay.selfRef — same rationale: nothing else retains
    /// the relay after `FlowRelay.relay` returns, so we anchor ourselves
    /// until `close()` fires.
    private var selfRef: UDPFlowRelay?

    init(
        flow: NEAppProxyUDPFlow,
        interface: NWInterface,
        appName: String,
        registry: ActiveFlowRelayRegistry? = nil
    ) {
        self.flow = flow
        self.interface = interface
        self.appName = appName
        self.registry = registry
    }

    // MARK: - Entry Point

    func start() {
        selfRef = self
        registry?.registerRelay(id: relayID) { [weak self] in
            self?.close(error: POSIXError(.EHOSTUNREACH))
        }
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            if let error {
                self?.close(error: error)
                return
            }
            self?.readLoop()
        }
    }

    // MARK: - Read Loop (flow → network)

    private func readLoop() {
        guard !isClosed() else { return }
        flow.readDatagrams { [weak self] datagrams, endpoints, error in
            guard let self else { return }
            if let error {
                self.close(error: error)
                return
            }
            guard let datagrams, let endpoints, !datagrams.isEmpty else {
                // EOF.
                self.close(error: nil)
                return
            }

            for (data, endpoint) in zip(datagrams, endpoints) {
                guard let host = endpoint as? NWHostEndpoint,
                      let converted = Self.convert(host) else {
                    continue
                }
                let conn = self.connection(for: converted)
                conn.send(content: data, completion: .contentProcessed { _ in })
            }
            self.readLoop()
        }
    }

    // MARK: - Connection Cache

    private func connection(for endpoint: Network.NWEndpoint) -> NWConnection {
        lock.lock()
        if let existing = connections[endpoint] {
            lock.unlock()
            return existing
        }
        // Pin to the user-selected physical interface — without this
        // the bypass datagrams would travel through whatever default
        // route the OS has (utun when a packet tunnel is up).
        let params = NWParameters.udp
        params.requiredInterface = interface

        let conn = NWConnection(to: endpoint, using: params)
        connections[endpoint] = conn
        lock.unlock()

        // First datagram to this destination — surface host:port so
        // per-endpoint diagnostics (DNS leaks, QUIC targets) are
        // observable. TCP gets this for free at flow open; UDP only
        // learns endpoints datagram-by-datagram.
        RingBufferLogger.shared.log(
            "\(appName) → \(interface.name)  UDP  \(Self.describe(endpoint))"
        )

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removeConnection(for: endpoint)
            default:
                break
            }
        }
        conn.start(queue: queue)
        receiveLoop(connection: conn, endpoint: endpoint)
        return conn
    }

    private func removeConnection(for endpoint: Network.NWEndpoint) {
        lock.lock()
        connections.removeValue(forKey: endpoint)
        lock.unlock()
    }

    // MARK: - Receive Loop (network → flow)

    private func receiveLoop(connection: NWConnection, endpoint: Network.NWEndpoint) {
        guard !isClosed() else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { return }   // ends this endpoint's loop; flow stays open
            guard let data, !data.isEmpty else { return }

            guard let neEndpoint = Self.convertBack(endpoint) else { return }
            self.flow.writeDatagrams([data], sentBy: [neEndpoint]) { [weak self] writeError in
                if writeError != nil {
                    self?.close(error: writeError)
                    return
                }
                self?.receiveLoop(connection: connection, endpoint: endpoint)
            }
        }
    }

    // MARK: - Endpoint Bridging

    private static func convert(_ host: NWHostEndpoint) -> Network.NWEndpoint? {
        guard let port = NWEndpoint.Port(host.port) else { return nil }
        return Network.NWEndpoint.hostPort(
            host: NWEndpoint.Host(host.hostname),
            port: port
        )
    }

    private static func describe(_ endpoint: Network.NWEndpoint) -> String {
        guard case let .hostPort(host, port) = endpoint else { return "?" }
        let hostname: String
        switch host {
        case .name(let name, _): hostname = name
        case .ipv4(let ipv4):    hostname = "\(ipv4)"
        case .ipv6(let ipv6):    hostname = "\(ipv6)"
        @unknown default:        hostname = "?"
        }
        return "\(hostname):\(port.rawValue)"
    }

    private static func convertBack(_ endpoint: Network.NWEndpoint) -> NWHostEndpoint? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        let hostname: String
        switch host {
        case .name(let name, _):      hostname = name
        case .ipv4(let ipv4):         hostname = "\(ipv4)"
        case .ipv6(let ipv6):         hostname = "\(ipv6)"
        @unknown default:             return nil
        }
        return NWHostEndpoint(hostname: hostname, port: "\(port.rawValue)")
    }

    // MARK: - Shutdown

    private func isClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func close(error: Error?) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let connectionsToCancel = Array(connections.values)
        connections.removeAll()
        lock.unlock()

        if let error {
            RingBufferLogger.shared.log(
                "\(appName)  UDP  flow failed: \(error.localizedDescription)"
            )
        }

        registry?.unregisterRelay(id: relayID)

        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        for conn in connectionsToCancel {
            conn.cancel()
        }
        selfRef = nil
    }
}
