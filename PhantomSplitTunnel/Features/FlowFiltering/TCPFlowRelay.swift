import Network
import NetworkExtension
import os.log

final class TCPFlowRelay {

    private let flow: NEAppProxyTCPFlow
    private let interface: NWInterface
    private let appName: String
    private let relayID = UUID()
    private weak var registry: ActiveFlowRelayRegistry?
    private var connection: NWConnection?
    private var closed = false
    private let lock = NSLock()

    private var remoteDescription: String = "?"

    private var selfRef: TCPFlowRelay?

    private let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomSplitTunnel",
        category: "relay.tcp"
    )

    init(
        flow: NEAppProxyTCPFlow,
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
            self?.startConnection()
        }
    }

    private func startConnection() {
        guard let hostEndpoint = flow.remoteEndpoint as? NWHostEndpoint else {
            os_log("Missing remoteEndpoint", log: log, type: .error)
            close(error: nil)
            return
        }

        remoteDescription = "\(hostEndpoint.hostname):\(hostEndpoint.port)"
        let host = NWEndpoint.Host(hostEndpoint.hostname)
        let port = NWEndpoint.Port(hostEndpoint.port) ?? .any

        let params = NWParameters.tcp
        params.requiredInterface = interface

        let conn = NWConnection(host: host, port: port, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state)
        }
        conn.start(queue: .global(qos: .utility))
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            pumpFlowToConnection()
            pumpConnectionToFlow()
        case .failed(let err):
            close(error: err)
        case .cancelled:
            close(error: nil)
        default:
            break
        }
    }

    // MARK: - Pump Loops

    private func pumpFlowToConnection() {
        guard !isClosed() else { return }
        flow.readData { [weak self] data, error in
            guard let self else { return }
            if let error {
                self.close(error: error)
                return
            }
            guard let data, !data.isEmpty else {
                self.close(error: nil)
                return
            }
            self.connection?.send(content: data, completion: .contentProcessed { [weak self] err in
                if let err {
                    self?.close(error: err)
                    return
                }
                self?.pumpFlowToConnection()
            })
        }
    }

    private func pumpConnectionToFlow() {
        guard !isClosed(), let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.close(error: error)
                return
            }
            guard let data, !data.isEmpty else {
                self.close(error: nil)
                return
            }
            self.flow.write(data) { [weak self] writeError in
                if let writeError {
                    self?.close(error: writeError)
                    return
                }
                self?.pumpConnectionToFlow()
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
        lock.unlock()

        if let error {
            RingBufferLogger.shared.log(
                "\(appName)  TCP  \(remoteDescription)  failed: \(error.localizedDescription)"
            )
        }

        registry?.unregisterRelay(id: relayID)

        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        connection?.cancel()
        connection = nil
        selfRef = nil
    }
}
