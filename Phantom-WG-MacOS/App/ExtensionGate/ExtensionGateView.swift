import SwiftUI
import AppKit

/// Root-level gate panel rendered whenever any of the three required
/// system extensions is not in `.activated`. Lists the three
/// extensions, surfaces the per-row status with a contextual action
/// button, and offers a single check-again entry (`gate_check_again`)
/// that re-pulls ground-truth state for all three at once.
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
                            // Only (re)submit an activation when the
                            // extension is actually missing or awaiting
                            // approval. Activation is NOT a free no-op
                            // for a live extension: ADR-0006 measured
                            // that even a byte-identical bundle stages a
                            // full replacement and tears down the running
                            // session. For an already-active (or still
                            // settling) extension, just open Settings.
                            if controller.status == .notInstalled
                                || controller.status == .needsApproval {
                                controller.activate()
                            }
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

#Preview("First run — Light") {
    ExtensionGateView()
        .previewEnvironment(gate: PreviewFixtures.gateCoordinator(
            tunnel: .notInstalled, split: .notInstalled, dns: .notInstalled
        ), scheme: .light)
        .frame(width: 560, height: 720)
}

#Preview("First run — Dark") {
    ExtensionGateView()
        .previewEnvironment(gate: PreviewFixtures.gateCoordinator(
            tunnel: .notInstalled, split: .notInstalled, dns: .notInstalled
        ), scheme: .dark)
        .frame(width: 560, height: 720)
}

#Preview("Mixed progress") {
    ExtensionGateView()
        .previewEnvironment(gate: PreviewFixtures.gateCoordinator(
            tunnel: .activated, split: .needsApproval, dns: .activating
        ))
        .frame(width: 560, height: 720)
}

#Preview("Failure") {
    ExtensionGateView()
        .previewEnvironment(gate: PreviewFixtures.gateCoordinator(
            tunnel: .activated,
            split: .failed("The code signature of the extension is invalid."),
            dns: .unknown
        ))
        .frame(width: 560, height: 720)
}
