import SwiftUI
import AppKit

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
