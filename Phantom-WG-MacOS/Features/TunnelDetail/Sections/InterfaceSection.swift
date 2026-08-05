import SwiftUI

/// WireGuard interface configuration, read-only — private key, local
/// addresses, DNS servers, and MTU. Values change only through
/// `TunnelEditView`'s raw-text editor.
struct InterfaceSection: View {
    let config: InterfaceConfig
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            PhantomStaticField(
                label: loc.t("detail_private_key"),
                value: config.privateKey.textual,
                axIdentifier: AXID.TunnelDetail.Interface.privateKey
            )
            PhantomStaticField(
                label: loc.t("detail_address"),
                value: config.addresses.map(\.textual).joined(separator: ", "),
                axIdentifier: AXID.TunnelDetail.Interface.addresses
            )
            PhantomStaticField(
                label: loc.t("detail_dns"),
                value: config.dnsServers.map(\.textual).joined(separator: ", "),
                axIdentifier: AXID.TunnelDetail.Interface.dnsServers
            )
            PhantomStaticField(
                label: loc.t("detail_mtu"),
                value: String(config.mtu),
                axIdentifier: AXID.TunnelDetail.Interface.mtu
            )
        } header: {
            Label(loc.t("detail_interface"), systemImage: "rectangle.connected.to.line.below")
        }
    }
}

// MARK: - Previews

#Preview {
    Form {
        InterfaceSection(config: PreviewFixtures.ghostConfig().wireguard.interface)
    }
    .formStyle(.grouped)
    .previewEnvironment()
    .frame(width: 560)
}
