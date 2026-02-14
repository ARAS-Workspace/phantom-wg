import SwiftUI

// MARK: - TunnelDetailView Helpers

extension TunnelDetailView {

    var statusTextColor: Color {
        switch tunnel.status {
        case .active: return .green
        case .activating, .waiting, .reasserting, .restarting: return .orange
        case .deactivating: return .orange
        case .inactive: return .secondary
        }
    }

    var statusBadgeColor: Color {
        switch tunnel.status {
        case .active: return .green
        case .activating, .waiting, .reasserting, .restarting: return .orange
        case .deactivating: return .orange
        case .inactive: return .secondary
        }
    }

    var statusBadgeIcon: String {
        switch tunnel.status {
        case .active: return "shield.checkered"
        case .activating, .waiting, .reasserting, .restarting: return "arrow.triangle.2.circlepath"
        case .deactivating: return "arrow.down.circle"
        case .inactive: return "shield.slash"
        }
    }
}

// MARK: - Stat Row

struct StatRow: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .secondary

    var body: some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundStyle(valueColor)
                .font(.system(.body, design: .monospaced))
        }
    }
}
