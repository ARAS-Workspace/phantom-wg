import SwiftUI

// MARK: - UI Appearance & Toggle Helpers

extension TunnelStatus {
    var color: Color {
        switch self {
        case .active:
            return .green
        case .activating, .waiting, .reasserting, .deactivating:
            return .orange
        case .inactive, .unknown:
            return .secondary
        }
    }

    var iconName: String {
        switch self {
        case .active:
            return "shield.checkered"
        case .activating, .waiting, .reasserting:
            return "arrow.triangle.2.circlepath"
        case .deactivating:
            return "arrow.down.circle"
        case .inactive:
            return "shield.slash"
        case .unknown:
            return "questionmark.circle"
        }
    }

    var isToggleOn: Bool {
        switch self {
        case .active, .activating, .waiting, .reasserting:
            return true
        case .inactive, .deactivating, .unknown:
            return false
        }
    }
}

// MARK: - Toggle Binding

extension TunnelContainer {
    @MainActor
    func toggleBinding(manager: TunnelsManager) -> Binding<Bool> {
        Binding(
            get: { self.status.isToggleOn },
            set: { isOn in
                Task { @MainActor in
                    if isOn {
                        manager.startActivation(of: self)
                    } else {
                        manager.startDeactivation(of: self)
                    }
                }
            }
        )
    }
}
