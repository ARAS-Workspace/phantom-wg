import SwiftUI

struct UninstallAlerts: ViewModifier {
    @Binding var errorMessage: String?
    @Binding var showingError: Bool
    @Binding var showingUninstallConfirm: Bool
    let onConfirm: () -> Void
    @Environment(LocalizationManager.self) private var loc

    func body(content: Content) -> some View {
        content
            .alert(loc.t("error"), isPresented: $showingError) {
                Button(loc.t("ok")) {}
                    .accessibilityIdentifier(AXID.TunnelList.errorAlertOK)
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(loc.t("uninstall_confirm_title"), isPresented: $showingUninstallConfirm) {
                Button(loc.t("cancel"), role: .cancel) {}
                    .accessibilityIdentifier(AXID.TunnelList.uninstallCancel)
                Button(loc.t("uninstall_confirm_action"), role: .destructive) {
                    onConfirm()
                }
                .accessibilityIdentifier(AXID.TunnelList.uninstallConfirm)
            } message: {
                Text(loc.t("uninstall_confirm_message"))
            }
    }
}

// MARK: - Previews

#Preview {
    PreviewBindingHost(String?.none) { errorMessage in
        PreviewBindingHost(false) { showingError in
            PreviewBindingHost(false) { showingConfirm in
                VStack(spacing: 12) {
                    Button("Show uninstall confirmation") {
                        showingConfirm.wrappedValue = true
                    }
                    Button("Show error alert") {
                        errorMessage.wrappedValue = "The extension refused to deactivate."
                        showingError.wrappedValue = true
                    }
                }
                .padding(40)
                .modifier(UninstallAlerts(
                    errorMessage: errorMessage,
                    showingError: showingError,
                    showingUninstallConfirm: showingConfirm,
                    onConfirm: {}
                ))
            }
        }
    }
    .previewEnvironment()
}
