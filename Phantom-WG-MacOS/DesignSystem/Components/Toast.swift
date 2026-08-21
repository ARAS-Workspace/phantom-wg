import SwiftUI

// MARK: - Model

enum ToastKind {
    case info, success, warning, error

    fileprivate var iconName: String {
        switch self {
        case .info:     return "info.circle.fill"
        case .success:  return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .error:    return "xmark.octagon.fill"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .info:     return .accentColor
        case .success:  return .green
        case .warning:  return .orange
        case .error:    return .red
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id: UUID
    let kind: ToastKind
    let message: String

    init(kind: ToastKind = .info, message: String) {
        self.id = UUID()
        self.kind = kind
        self.message = message
    }

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

// MARK: - Center

@Observable
@MainActor
final class ToastCenter {

    private(set) var current: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ toast: Toast, duration: Duration = .seconds(3)) {
        dismissTask?.cancel()
        current = toast
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func info(_ message: String) { show(Toast(kind: .info, message: message)) }
    func success(_ message: String) { show(Toast(kind: .success, message: message)) }
    func warning(_ message: String) { show(Toast(kind: .warning, message: message)) }
    func error(_ message: String) { show(Toast(kind: .error, message: message)) }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

// MARK: - Banner

struct ToastBanner: View {
    let toast: Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.kind.iconName)
                .foregroundStyle(toast.kind.tint)
                .font(.body)

            Text(toast.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

// MARK: - Overlay

private struct ToastOverlayModifier: ViewModifier {
    @Environment(ToastCenter.self) private var toasts

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            Group {
                if let toast = toasts.current {
                    ToastBanner(toast: toast, onDismiss: toasts.dismiss)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(
                .spring(response: 0.35, dampingFraction: 0.85),
                value: toasts.current?.id
            )
        }
    }
}

extension View {
    func toastOverlay() -> some View {
        modifier(ToastOverlayModifier())
    }
}

// MARK: - Previews

#Preview("Banner kinds — Light") {
    VStack(spacing: 12) {
        ToastBanner(toast: Toast(kind: .info, message: "Interface switched to automatic selection."), onDismiss: {})
        ToastBanner(toast: Toast(kind: .success, message: "Tunnel configuration saved."), onDismiss: {})
        ToastBanner(toast: Toast(kind: .warning, message: "Selected interface is unavailable."), onDismiss: {})
        ToastBanner(toast: Toast(kind: .error, message: "The extension refused the configuration."), onDismiss: {})
    }
    .padding(24)
    .frame(width: 560)
    .preferredColorScheme(.light)
}

#Preview("Banner kinds — Dark") {
    VStack(spacing: 12) {
        ToastBanner(toast: Toast(kind: .info, message: "Interface switched to automatic selection."), onDismiss: {})
        ToastBanner(toast: Toast(kind: .success, message: "Tunnel configuration saved."), onDismiss: {})
        ToastBanner(toast: Toast(kind: .warning, message: "Selected interface is unavailable."), onDismiss: {})
        ToastBanner(toast: Toast(kind: .error, message: "The extension refused the configuration."), onDismiss: {})
    }
    .padding(24)
    .frame(width: 560)
    .preferredColorScheme(.dark)
}

#Preview("Live center") {
    ToastDemoHost()
        .previewEnvironment()
        .frame(width: 560, height: 300)
}

private struct ToastDemoHost: View {
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack(spacing: 12) {
            Button("Info") { toasts.info("Interface switched to automatic selection.") }
            Button("Success") { toasts.success("Tunnel configuration saved.") }
            Button("Warning") { toasts.warning("Selected interface is unavailable.") }
            Button("Error") { toasts.error("The extension refused the configuration.") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toastOverlay()
    }
}
