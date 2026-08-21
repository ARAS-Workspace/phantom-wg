import Foundation
import Network

// MARK: - Physical Interface Resolver

@Observable
@MainActor
final class PhysicalInterfaceResolver {

    private(set) var interfaces: [NWInterface] = []

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private let queue = DispatchQueue(
        label: "com.remrearas.Phantom-WG-MacOS.interface-monitor",
        qos: .utility
    )

    func start() {
        guard monitor == nil else { return }
        let pathMonitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let found = path.availableInterfaces
            Task { @MainActor in
                self?.apply(interfaces: found)
            }
        }
        pathMonitor.start(queue: queue)
        monitor = pathMonitor
    }

    deinit {
        monitor?.cancel()
    }

    // MARK: - Private

    private func apply(interfaces: [NWInterface]) {
        var seen = Set<String>()
        self.interfaces = interfaces.filter { seen.insert($0.name).inserted }
    }
}

// MARK: - Display Helpers

extension NWInterface {
    var displayLabel: String {
        let prefix: String
        switch type {
        case .wifi:          prefix = "Wi-Fi"
        case .wiredEthernet: prefix = "Ethernet"
        case .cellular:      prefix = "Cellular"
        case .loopback:      prefix = "Loopback"
        case .other:         prefix = "Other"
        @unknown default:    prefix = "Unknown"
        }
        return "\(prefix) (\(name))"
    }
}
