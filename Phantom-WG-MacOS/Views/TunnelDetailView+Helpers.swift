import SwiftUI

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
