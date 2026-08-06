import SwiftUI

// MARK: - UI Appearance & Toggle Helpers

extension TunnelStatus {
    /// Status → color mapping used by status indicators in tunnel list and detail views.
    var color: Color {
        switch self {
        case .active:
            return .green
        case .activating, .waiting, .reasserting, .restarting, .deactivating:
            return .orange
        case .inactive:
            return .secondary
        }
    }

    /// Status → SF Symbol name used alongside the status color.
    var iconName: String {
        switch self {
        case .active:
            return "shield.checkered"
        case .activating, .waiting, .reasserting, .restarting:
            return "arrow.triangle.2.circlepath"
        case .deactivating:
            return "arrow.down.circle"
        case .inactive:
            return "shield.slash"
        }
    }

    /// Toggle switch ON state derived from the status.
    var isToggleOn: Bool {
        switch self {
        case .active, .activating, .waiting, .reasserting, .restarting:
            return true
        case .inactive, .deactivating:
            return false
        }
    }
}

// MARK: - Toggle Binding

extension TunnelContainer {
    /// Produces the Binding used by tunnel row / detail toggles.
    /// Activation/deactivation is routed through TunnelsManager. The
    /// setter hops out of the view-update transaction: the activation
    /// path mutates observed state synchronously (`status`,
    /// `waitingTunnel`), and doing that inside a binding write is the
    /// "Modifying state during view update" warning — with layout
    /// glitches to match. One main-actor turn later is invisible to
    /// the user and legal for SwiftUI; the `status == .inactive`
    /// guards in the manager keep a double flip idempotent.
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
