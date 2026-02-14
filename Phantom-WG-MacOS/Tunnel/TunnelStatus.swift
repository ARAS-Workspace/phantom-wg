import Foundation
import NetworkExtension

enum TunnelStatus: Equatable {
    case inactive
    case activating
    case active
    case deactivating
    case reasserting
    case restarting
    case waiting

    init(from systemStatus: NEVPNStatus) {
        switch systemStatus {
        case .connected:
            self = .active
        case .connecting:
            self = .activating
        case .disconnected:
            self = .inactive
        case .disconnecting:
            self = .deactivating
        case .reasserting:
            self = .reasserting
        case .invalid:
            self = .inactive
        @unknown default:
            self = .inactive
        }
    }

    var localizedDescription: String {
        let loc = LocalizationManager.shared
        switch self {
        case .inactive: return loc.t("status_inactive")
        case .activating: return loc.t("status_activating")
        case .active: return loc.t("status_active")
        case .deactivating: return loc.t("status_deactivating")
        case .reasserting: return loc.t("status_reasserting")
        case .restarting: return loc.t("status_restarting")
        case .waiting: return loc.t("status_waiting")
        }
    }

    var isActiveOrTransitioning: Bool {
        switch self {
        case .active, .activating, .deactivating, .reasserting, .restarting, .waiting:
            return true
        case .inactive:
            return false
        }
    }
}
