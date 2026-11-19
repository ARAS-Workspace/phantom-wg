import SwiftUI

/// WireGuard interface configuration, read-only — the public key
/// derived from the private key, local addresses, DNS servers, MTU,
/// and, when the configuration carries them, the DNS search domains
/// and the listen port. The private key itself appears only in
/// `TunnelEditView`'s raw-text editor, where values change.
struct InterfaceSection: View {
    let config: InterfaceConfig
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            PhantomStaticField(
                label: loc.t("detail_public_key"),
                value: config.privateKey.derivedPublicKey?.textual ?? "—",
                axIdentifier: AXID.TunnelDetail.Interface.publicKey
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
            if !config.dnsSearch.isEmpty {
                PhantomStaticField(
                    label: loc.t("detail_dns_search"),
                    value: config.dnsSearch.joined(separator: ", "),
                    axIdentifier: AXID.TunnelDetail.Interface.dnsSearch
                )
            }
            PhantomStaticField(
                label: loc.t("detail_mtu"),
                value: config.mtu == InterfaceDraft.automaticMTU ? loc.t("detail_mtu_automatic") : String(config.mtu),
                axIdentifier: AXID.TunnelDetail.Interface.mtu
            )
            if let listenPort = config.listenPort {
                PhantomStaticField(
                    label: loc.t("detail_listen_port"),
                    value: String(listenPort),
                    axIdentifier: AXID.TunnelDetail.Interface.listenPort
                )
            }
        } header: {
            Label(loc.t("detail_interface"), systemImage: "rectangle.connected.to.line.below")
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    Form {
        InterfaceSection(config: PreviewFixtures.ghostConfig().wireguard.interface)
    }
    .formStyle(.grouped)
    .previewEnvironment(scheme: .light)
}

#Preview("Dark") {
    Form {
        InterfaceSection(config: PreviewFixtures.ghostConfig().wireguard.interface)
    }
    .formStyle(.grouped)
    .previewEnvironment(scheme: .dark)
}
