import SwiftUI
import AppKit

/// Root-level gate panel rendered whenever any of the three required
/// system extensions is not in `.activated`. Lists the three
/// extensions, surfaces the per-row status with a contextual action
/// button, and offers a single "Tekrar Kontrol Et" entry that
/// re-pulls ground-truth state for all three at once.
struct ExtensionGateView: View {
    @Environment(ExtensionGateCoordinator.self) private var coordinator
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        VStack(spacing: 24) {
            header

            VStack(spacing: 10) {
                ForEach(coordinator.controllers, id: \.bundleID) { controller in
                    ExtensionGateRow(
                        controller: controller,
                        onActivate: { controller.activate() },
                        onOpenSettings: {
                            // Defensive existence + approval check
                            // before sending the user to Settings.
                            // `activate()` is idempotent at the OS
                            // level: missing extension reinstalls,
                            // pending approval re-surfaces the prompt,
                            // already-active is a silent `.completed`.
                            // This way the toggle the user is about
                            // to look for is guaranteed to exist in
                            // the Network Extensions pane.
                            controller.activate()
                            openSystemSettings()
                        },
                        onRetry: { controller.activate() }
                    )
                }
            }
            .padding(.horizontal, 32)

            Button(loc.t("gate_check_again")) {
                coordinator.checkAll()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AXID.ExtensionGate.checkAgain)

            Spacer()
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(loc.t("gate_title"))
                .font(.title2)
                .bold()
            Text(loc.t("gate_description"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    /// Opens the System Settings pane that hosts Network Extensions.
    /// Sequoia and later list extensions under Login Items &
    /// Extensions; Sonoma keeps them under Privacy & Security.
    private func openSystemSettings() {
        if #available(macOS 15.0, *) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        }
    }
}

// MARK: - Previews

#Preview("First run") {
    ExtensionGateView()
        .previewEnvironment(gate: PreviewFixtures.gateCoordinator(
            tunnel: .notInstalled, split: .notInstalled, dns: .notInstalled
        ))
        .frame(width: 480, height: 720)
}

#Preview("Mixed progress") {
    ExtensionGateView()
        .previewEnvironment(gate: PreviewFixtures.gateCoordinator(
            tunnel: .activated, split: .needsApproval, dns: .activating
        ))
        .frame(width: 480, height: 720)
}

#Preview("Failure") {
    ExtensionGateView()
        .previewEnvironment(gate: PreviewFixtures.gateCoordinator(
            tunnel: .activated,
            split: .failed("The code signature of the extension is invalid."),
            dns: .unknown
        ))
        .frame(width: 480, height: 720)
}
