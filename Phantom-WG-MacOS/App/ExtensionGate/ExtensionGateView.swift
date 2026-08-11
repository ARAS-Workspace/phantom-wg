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

    /// Opens the System Settings pane that hosts Network Extensions —
    /// Login Items & Extensions on every macOS this app runs on (the
    /// 15.1 floor retired the Sonoma-era Privacy & Security fallback).
    private func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
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
