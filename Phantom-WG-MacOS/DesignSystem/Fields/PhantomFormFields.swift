import SwiftUI

/// Reusable form field components.
///
/// Independent SwiftUI views extracted from the textField / portField /
/// intField builders that previously lived inside TunnelDetailView.
/// Disabled state is passed by the caller (typically `tunnel.status == .inactive`).
/// Error messages are optional — when non-nil, the label turns red and a
/// compact description is shown directly beneath the input.
///
/// The `axIdentifier` parameter attaches a stable accessibility identifier
/// to the underlying `TextField` so automation and accessibility tooling
/// can address it by string.

/// Monospaced text input field — label on top, value below, optional
/// inline error beneath. Becomes disabled while the tunnel is active
/// and switches to the secondary foreground color.
struct PhantomTextField: View {
    let label: String
    @Binding var text: String
    let isDisabled: Bool
    var errorMessage: String?
    var axIdentifier: String?

    var body: some View {
        let hasError = errorMessage != nil
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(hasError ? Color.red : Color.secondary)
            TextField(label, text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .disabled(isDisabled)
                .foregroundStyle(isDisabled ? .secondary : .primary)
                .padding(.leading, hasError ? 8 : 0)
                .overlay(alignment: .leading) {
                    if hasError {
                        Rectangle()
                            .fill(Color.red.opacity(0.9))
                            .frame(width: 2)
                            .padding(.vertical, 1)
                    }
                }
                .accessibilityIdentifier(axIdentifier ?? "")
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.default, value: hasError)
        .padding(.vertical, 2)
    }
}

/// Raw-string numeric field used for draft-backed numeric inputs
/// (ports, MTU, keepalive). Keeps the user's text verbatim so that
/// invalid entries remain editable; validation is the caller's
/// responsibility (draft → `validate()`).
struct PhantomStringNumericField: View {
    let label: String
    @Binding var text: String
    let isDisabled: Bool
    var errorMessage: String?
    var axIdentifier: String?

    var body: some View {
        let hasError = errorMessage != nil
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(hasError ? Color.red : Color.secondary)
            TextField(label, text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .disabled(isDisabled)
                .foregroundStyle(isDisabled ? .secondary : .primary)
                .padding(.leading, hasError ? 8 : 0)
                .overlay(alignment: .leading) {
                    if hasError {
                        Rectangle()
                            .fill(Color.red.opacity(0.9))
                            .frame(width: 2)
                            .padding(.vertical, 1)
                    }
                }
                .accessibilityIdentifier(axIdentifier ?? "")
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.default, value: hasError)
        .padding(.vertical, 2)
    }
}
