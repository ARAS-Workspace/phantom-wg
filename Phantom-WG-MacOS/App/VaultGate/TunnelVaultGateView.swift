import SwiftUI

struct TunnelVaultGateView: View {
    @Environment(TunnelVaultSession.self) private var session
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        VStack(spacing: 20) {
            Image("PhantomLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)

            switch session.state {
            case .connecting, .ready:
                ProgressView {
                    Text(loc.t("vault_gate_connecting"))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .accessibilityIdentifier(AXID.VaultGate.connecting)
            case .silent:
                failure(
                    title: "vault_gate_silent_title",
                    message: "vault_gate_silent_message",
                    axid: AXID.VaultGate.silentError
                )
            case .doorFailed:
                failure(
                    title: "vault_gate_door_title",
                    message: "vault_gate_door_message",
                    axid: AXID.VaultGate.doorError
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await session.establish() }
    }

    private func failure(title: String, message: String, axid: String) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text(loc.t(title))
                    .font(.title3)
                    .bold()
                Text(loc.t(message))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(axid)

            Button(loc.t("gate_check_again")) {
                session.checkAgain()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AXID.VaultGate.checkAgain)
        }
    }
}

// MARK: - Previews

#Preview("Connecting — Light") {
    TunnelVaultGateView()
        .previewEnvironment(vaultSession: PreviewFixtures.vaultSession(state: .connecting), scheme: .light)
        .frame(width: 560, height: 720)
}

#Preview("Connecting — Dark") {
    TunnelVaultGateView()
        .previewEnvironment(vaultSession: PreviewFixtures.vaultSession(state: .connecting), scheme: .dark)
        .frame(width: 560, height: 720)
}

#Preview("Extension silent — Light") {
    TunnelVaultGateView()
        .previewEnvironment(vaultSession: PreviewFixtures.vaultSession(state: .silent), scheme: .light)
        .frame(width: 560, height: 720)
}

#Preview("Extension silent — Dark") {
    TunnelVaultGateView()
        .previewEnvironment(vaultSession: PreviewFixtures.vaultSession(state: .silent), scheme: .dark)
        .frame(width: 560, height: 720)
}

#Preview("Vault door failed — Light") {
    TunnelVaultGateView()
        .previewEnvironment(vaultSession: PreviewFixtures.vaultSession(state: .doorFailed), scheme: .light)
        .frame(width: 560, height: 720)
}

#Preview("Vault door failed — Dark") {
    TunnelVaultGateView()
        .previewEnvironment(vaultSession: PreviewFixtures.vaultSession(state: .doorFailed), scheme: .dark)
        .frame(width: 560, height: 720)
}
