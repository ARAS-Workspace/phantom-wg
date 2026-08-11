import SwiftUI

/// Lock screen between the vault gate and the tunnel content. When
/// another local user's VPN holds the system's one exclusive slot,
/// activating against it only feeds the cross-user on-demand fight —
/// so the app names the situation and waits, and the moment the slot
/// is freed in System Settings > VPN the user's own list appears.
/// Mirrors the vault gate's idiom: the state names what is standing
/// in the way, the buttons are the two honest ways forward.
struct ConnectionGateView: View {
    @Environment(ConnectionGateCoordinator.self) private var gate
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        VStack(spacing: 20) {
            Image("PhantomLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)

            switch gate.state {
            case .checking, .slotFree:
                ProgressView {
                    Text(loc.t("connection_gate_checking"))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .accessibilityIdentifier(AXID.ConnectionGate.checking)
            case .slotHeld(let holderName):
                held(holderName)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func held(_ holderName: String?) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text(loc.t("connection_gate_title"))
                    .font(.title3)
                    .bold()
                Text(holderName.map { loc.t("connection_gate_message_named", $0) }
                    ?? loc.t("connection_gate_message"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AXID.ConnectionGate.heldMessage)

            HStack(spacing: 12) {
                Button(loc.t("gate_open_settings")) {
                    openVPNSettings()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(AXID.ConnectionGate.openSettings)

                Button(loc.t("gate_check_again")) {
                    gate.checkAgain()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AXID.ConnectionGate.checkAgain)
            }
        }
    }

    /// System Settings > VPN. The pane identifier was read off the
    /// system's own VPN.appex (`CFBundleIdentifier`); if the deep link
    /// is refused on some OS, fall back to System Settings itself —
    /// the button's promise stays truthful either way.
    private func openVPNSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!)
        }
    }
}

// MARK: - Previews

#Preview("Held — named holder") {
    ConnectionGateView()
        .environment(ConnectionGateCoordinator(
            vault: PreviewVaultClient(configs: []),
            initialState: .slotHeld(holderName: "Home Lab")
        ))
        .environment(LocalizationManager.shared)
        .frame(width: 560, height: 720)
}

#Preview("Held — unnamed holder") {
    ConnectionGateView()
        .environment(ConnectionGateCoordinator(
            vault: PreviewVaultClient(configs: []),
            initialState: .slotHeld(holderName: nil)
        ))
        .environment(LocalizationManager.shared)
        .frame(width: 560, height: 720)
}

#Preview("Checking") {
    ConnectionGateView()
        .environment(ConnectionGateCoordinator(
            vault: PreviewVaultClient(configs: []),
            initialState: .checking
        ))
        .environment(LocalizationManager.shared)
        .frame(width: 560, height: 720)
}
