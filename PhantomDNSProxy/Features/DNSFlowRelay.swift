import Foundation
import Network
import NetworkExtension
import os.log

enum DNSFlowRelay {

    static let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomDNSProxy",
        category: "relay"
    )

    static func isPeerClose(_ error: Error) -> Bool {
        let message = error.localizedDescription
        return message.contains("peer closed")
            || message.contains("peer reset")
    }

    static func relay(
        _ flow: NEAppProxyFlow,
        appName: String,
        resolver: String,
        boundTo interface: NWInterface?
    ) -> Bool {
        if let udp = flow as? NEAppProxyUDPFlow {
            DNSUDPFlowRelay(
                flow: udp,
                appName: appName,
                resolver: resolver,
                interface: interface
            ).start()
            return true
        }
        if let tcp = flow as? NEAppProxyTCPFlow {
            DNSTCPFlowRelay(
                flow: tcp,
                appName: appName,
                resolver: resolver,
                interface: interface
            ).start()
            return true
        }
        os_log("Unknown DNS flow type — declining", log: log, type: .error)
        return false
    }
}

// MARK: - UDP

final class DNSUDPFlowRelay {

    private let flow: NEAppProxyUDPFlow
    private let appName: String
    private let resolverHost: Network.NWEndpoint.Host
    private let interface: NWInterface?
    private let queue = DispatchQueue(label: "phantom-dns.udp", qos: .utility)

    private let lock = NSLock()
    private var connection: NWConnection?
    private var pendingSources: [NWHostEndpoint] = []
    private var closed = false

    private var selfRef: DNSUDPFlowRelay?

    init(
        flow: NEAppProxyUDPFlow,
        appName: String,
        resolver: String,
        interface: NWInterface?
    ) {
        self.flow = flow
        self.appName = appName
        self.resolverHost = Network.NWEndpoint.Host(resolver)
        self.interface = interface
    }

    func start() {
        selfRef = self

        let params = NWParameters.udp
        if let interface {
            params.requiredInterface = interface
        }
        let conn = NWConnection(host: resolverHost, port: 53, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            self?.handle(state: state)
        }
        conn.start(queue: queue)
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            flow.open(withLocalEndpoint: nil) { [weak self] error in
                if let error {
                    self?.close(error: error)
                    return
                }
                self?.readFlow()
                self?.readConnection()
            }
        case .failed(let err):
            close(error: err)
        case .cancelled:
            close(error: nil)
        default:
            break
        }
    }

    private func readFlow() {
        guard !isClosed() else { return }
        flow.readDatagrams { [weak self] datagrams, endpoints, error in
            guard let self else { return }
            if let error {
                self.close(error: error)
                return
            }
            guard let datagrams, let endpoints, !datagrams.isEmpty else {
                self.close(error: nil)
                return
            }

            for (data, endpoint) in zip(datagrams, endpoints) {
                guard let host = endpoint as? NWHostEndpoint else { continue }
                self.lock.lock()
                self.pendingSources.append(host)
                self.lock.unlock()

                self.connection?.send(content: data, completion: .contentProcessed { _ in })
            }
            self.readFlow()
        }
    }

    private func readConnection() {
        guard !isClosed(), let conn = connection else { return }
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { return }
            guard let data, !data.isEmpty else { return }

            self.lock.lock()
            let source = self.pendingSources.first
            if !self.pendingSources.isEmpty {
                self.pendingSources.removeFirst()
            }
            self.lock.unlock()

            guard let source else {
                self.readConnection()
                return
            }

            self.flow.writeDatagrams([data], sentBy: [source]) { [weak self] writeError in
                if let writeError {
                    self?.close(error: writeError)
                    return
                }
                self?.readConnection()
            }
        }
    }

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
        let conn = connection
        connection = nil
        lock.unlock()

        if let error, !DNSFlowRelay.isPeerClose(error) {
            os_log("UDP %{public}@ flow failed: %{public}@",
                   log: DNSFlowRelay.log, type: .error,
                   appName, error.localizedDescription)
        }

        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        conn?.cancel()
        selfRef = nil
    }
}

// MARK: - TCP

final class DNSTCPFlowRelay {

    private let flow: NEAppProxyTCPFlow
    private let appName: String
    private let resolverHost: Network.NWEndpoint.Host
    private let interface: NWInterface?
    private let queue = DispatchQueue(label: "phantom-dns.tcp", qos: .utility)

    private let lock = NSLock()
    private var connection: NWConnection?
    private var closed = false

    private var selfRef: DNSTCPFlowRelay?

    init(
        flow: NEAppProxyTCPFlow,
        appName: String,
        resolver: String,
        interface: NWInterface?
    ) {
        self.flow = flow
        self.appName = appName
        self.resolverHost = Network.NWEndpoint.Host(resolver)
        self.interface = interface
    }

    func start() {
        selfRef = self

        let params = NWParameters.tcp
        if let interface {
            params.requiredInterface = interface
        }
        let conn = NWConnection(host: resolverHost, port: 53, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            self?.handle(state: state)
        }
        conn.start(queue: queue)
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            flow.open(withLocalEndpoint: nil) { [weak self] error in
                if let error {
                    self?.close(error: error)
                    return
                }
                self?.pumpFlowToConnection()
                self?.pumpConnectionToFlow()
            }
        case .failed(let err):
            close(error: err)
        case .cancelled:
            close(error: nil)
        default:
            break
        }
    }

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
        let conn = connection
        connection = nil
        lock.unlock()

        if let error, !DNSFlowRelay.isPeerClose(error) {
            os_log("TCP %{public}@ flow failed: %{public}@",
                   log: DNSFlowRelay.log, type: .error,
                   appName, error.localizedDescription)
        }

        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        conn?.cancel()
        selfRef = nil
    }
}
