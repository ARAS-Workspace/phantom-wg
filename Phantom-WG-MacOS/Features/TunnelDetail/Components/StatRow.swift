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

// MARK: - Previews

#Preview {
    Form {
        StatRow(icon: "hand.wave", label: "Latest Handshake", value: "12 seconds ago")
        StatRow(icon: "arrow.down.circle", label: "Data Received", value: "45.12 MB", valueColor: .green)
        StatRow(icon: "arrow.up.circle", label: "Data Sent", value: "8.79 MB", valueColor: .blue)
    }
    .formStyle(.grouped)
    .frame(width: 560)
}
