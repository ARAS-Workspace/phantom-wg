import SwiftUI

struct PhantomStaticField: View {
    let label: String
    let value: String
    var axIdentifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier(axIdentifier ?? "")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Previews

#Preview("Light") {
    Form {
        Section {
            PhantomStaticField(label: "Endpoint", value: "edge.phantom.tc:51820")
            PhantomStaticField(label: "MTU", value: "1420")
        }
    }
    .formStyle(.grouped)
    .frame(width: 560)
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    Form {
        Section {
            PhantomStaticField(label: "Endpoint", value: "edge.phantom.tc:51820")
            PhantomStaticField(label: "MTU", value: "1420")
        }
    }
    .formStyle(.grouped)
    .frame(width: 560)
    .preferredColorScheme(.dark)
}
