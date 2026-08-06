import SwiftUI

/// Read-only field row — label on top, selectable monospaced value
/// below. The tunnel detail sections are built from these now that
/// configuration editing happens exclusively in `TunnelEditView`'s
/// raw-text editor. `axIdentifier` attaches a stable accessibility
/// identifier so automation and accessibility tooling can address
/// the value by string.
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
    .preferredColorScheme(.dark)
}
