#if DEBUG && targetEnvironment(simulator)
import Foundation
import NetworkExtension

/// Stands in for the system's session of one configuration — the object
/// a real `NETunnelProviderManager` reaches through `connection`. It owns
/// the status, posts `NEVPNStatusDidChange` with itself as the object on
/// every change, keeps the last disconnect error, and runs the simulated
/// extension process while the tunnel is up.
///
/// Main thread only.
final class SimulatedSession {

    let configurationID: UUID
    private(set) var status: NEVPNStatus = .disconnected
    private(set) var lastDisconnectError: Error?
    private(set) var process: SimulatedPacketTunnelProcess?
    private weak var system: SimulatedNetworkExtension?
    private var generation = 0

    init(configurationID: UUID, system: SimulatedNetworkExtension) {
        self.configurationID = configurationID
        self.system = system
    }

    func start(protocolConfiguration: NETunnelProviderProtocol?) {
        guard status == .disconnected || status == .invalid else { return }
        generation += 1
        let expected = generation
        let process = SimulatedPacketTunnelProcess(session: self)
        self.process = process
        transition(to: .connecting)
        process.startTunnel(protocolConfiguration: protocolConfiguration) { [weak self] error in
            guard let self, self.generation == expected else { return }
            if let error {
                self.end(with: error)
            } else {
                self.transition(to: .connected)
            }
        }
    }

    func stop(reason: NEProviderStopReason = .userInitiated) {
        guard status == .connecting || status == .connected || status == .reasserting else { return }
        generation += 1
        let expected = generation
        transition(to: .disconnecting)
        guard let process else {
            end(with: nil)
            return
        }
        process.stopTunnel(reason: reason) { [weak self] in
            guard let self, self.generation == expected else { return }
            self.end(with: nil)
        }
    }

    func setReasserting(_ reasserting: Bool) {
        guard status == .connected || status == .reasserting else { return }
        transition(to: reasserting ? .reasserting : .connected)
    }

    private func end(with error: Error?) {
        process = nil
        lastDisconnectError = error
        transition(to: .disconnected)
        system?.sessionDidEnd(configurationID)
    }

    private func transition(to newStatus: NEVPNStatus) {
        status = newStatus
        let name = system?.record(configurationID).map(SimulatedNetworkExtension.label) ?? configurationID.uuidString
        SimulatedNetworkExtension.log.info("session \(name, privacy: .public) status=\(newStatus.rawValue)")
        NotificationCenter.default.post(name: .NEVPNStatusDidChange, object: self)
    }
}
#endif
