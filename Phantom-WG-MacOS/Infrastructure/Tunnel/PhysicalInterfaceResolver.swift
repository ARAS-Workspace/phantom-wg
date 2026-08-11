import Foundation
import Network

// MARK: - Physical Interface Resolver

/// Discovers the physical interfaces that the split-tunnel picker can
/// offer. Intentionally ignores `.other` (tunnels, utun*) and
/// `.loopback` — only real egress paths qualify. The list is
/// `@Observable` so the picker refreshes when the user plugs in an
/// Ethernet cable or toggles Wi-Fi.
///
/// This resolver lives in the main app process only. The extension
/// runs its own monitor because it needs to react to interface loss
/// mid-session and can't reach back into the app.
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
        // Dedupe on BSD name — a single physical NIC can appear multiple
        // times under different address families.
        var seen = Set<String>()
        self.interfaces = interfaces.filter { seen.insert($0.name).inserted }
    }
}

// MARK: - Display Helpers

extension NWInterface {
    /// Human-readable label for the picker, e.g. "Wi-Fi (en0)".
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
