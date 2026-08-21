import Foundation
import Network

final class InterfaceMonitor {

    var onChange: ((NWInterface?) -> Void)?

    var current: NWInterface? {
        syncQueue.sync { _current }
    }

    private var _current: NWInterface?

    private var selection: InterfaceSelection = .auto
    private var available: [NWInterface] = []

    private let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
    private let queue = DispatchQueue(
        label: "com.remrearas.Phantom-WG-MacOS.interface-monitor",
        qos: .utility
    )
    private let syncQueue = DispatchQueue(
        label: "com.remrearas.Phantom-WG-MacOS.interface-monitor.sync"
    )

    // MARK: - Lifecycle

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.syncQueue.async {
                self?.apply(availableInterfaces: path.availableInterfaces)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    // MARK: - Selection

    func setSelection(_ selection: InterfaceSelection) {
        syncQueue.async { [weak self] in
            self?.selection = selection
            self?.resolve()
        }
    }

    // MARK: - Private

    private func apply(availableInterfaces: [NWInterface]) {
        var seen = Set<String>()
        available = availableInterfaces.filter { seen.insert($0.name).inserted }
        resolve()
    }

    private func resolve() {
        let resolved: NWInterface?
        switch selection {
        case .auto:
            resolved = available.first(where: { $0.type == .wiredEthernet })
                ?? available.first(where: { $0.type == .wifi })
                ?? available.first
        case .explicit(let name):
            resolved = available.first(where: { $0.name == name })
        }

        let previous = _current
        _current = resolved

        if previous?.name != resolved?.name {
            onChange?(resolved)
        }
    }
}
