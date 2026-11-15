import Network
import NetworkExtension

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
        flow.open(withLocalFlowEndpoint: nil) { [weak self] error in
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
        flow.readDatagrams { [weak self] (datagrams: [(Data, Network.NWEndpoint)]?, error: Error?) in
            guard let self else { return }
            if let error {
                self.close(error: error)
                return
            }
            guard let datagrams, !datagrams.isEmpty else {
                self.close(error: nil)
                return
            }

            for (data, endpoint) in datagrams {
                guard case .hostPort = endpoint else { continue }
                let conn = self.connection(for: endpoint)
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
        let params = NWParameters.udp
        params.requiredInterface = interface

        let conn = NWConnection(to: endpoint, using: params)
        connections[endpoint] = conn
        lock.unlock()

        RingBufferLogger.shared.log(
            "\(appName) → \(interface.name)  UDP  \(endpoint.relayDescription)"
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
            if error != nil { return }
            guard let data, !data.isEmpty else { return }

            self.flow.writeDatagrams([(data, endpoint)]) { [weak self] writeError in
                if writeError != nil {
                    self?.close(error: writeError)
                    return
                }
                self?.receiveLoop(connection: connection, endpoint: endpoint)
            }
        }
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

// MARK: - Endpoint Description

extension Network.NWEndpoint {

    var relayDescription: String {
        guard case let .hostPort(host, port) = self else { return "?" }
        let hostname: String
        switch host {
        case .name(let name, _): hostname = name
        case .ipv4(let ipv4):    hostname = "\(ipv4)"
        case .ipv6(let ipv6):    hostname = "\(ipv6)"
        @unknown default:        hostname = "?"
        }
        return "\(hostname):\(port.rawValue)"
    }
}
