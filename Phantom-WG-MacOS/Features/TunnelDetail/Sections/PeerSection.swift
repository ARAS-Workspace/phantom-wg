import SwiftUI

struct PeerSection: View {
    let config: PeerConfig
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        CardSection {
            PhantomStaticField(
                label: loc.t("detail_public_key"),
                value: config.publicKey.textual,
                axIdentifier: AXID.TunnelDetail.Peer.publicKey
            )
            if config.presharedKey != nil {
                PhantomStaticField(
                    label: loc.t("detail_preshared_key"),
                    value: loc.t("detail_preshared_key_enabled"),
                    axIdentifier: AXID.TunnelDetail.Peer.presharedKey
                )
            }
            PhantomStaticField(
                label: loc.t("detail_allowed_ips"),
                value: config.allowedIPs.map(\.textual).joined(separator: ", "),
                axIdentifier: AXID.TunnelDetail.Peer.allowedIPs
            )
            if let endpoint = config.endpoint {
                PhantomStaticField(
                    label: loc.t("detail_endpoint"),
                    value: endpoint.textual,
                    axIdentifier: AXID.TunnelDetail.Peer.endpoint
                )
            }
            PhantomStaticField(
                label: loc.t("detail_keepalive"),
                value: config.persistentKeepalive == PeerDraft.keepaliveOff
                    ? loc.t("detail_keepalive_off")
                    : String(config.persistentKeepalive),
                axIdentifier: AXID.TunnelDetail.Peer.keepalive
            )
        } header: {
            Label(loc.t("detail_peer"), systemImage: "point.3.connected.trianglepath.dotted")
        }
    }
}

// MARK: - Previews

#Preview("With preshared key") {
    VStack(alignment: .leading, spacing: 16) {
        PeerSection(config: PreviewFixtures.ghostConfig().wireguard.peer)
    }
    .padding(20)
    .previewEnvironment()
    .frame(width: WindowSizing.ideal.width)
}

#Preview("Without preshared key") {
    var peer = PreviewFixtures.ghostConfig().wireguard.peer
    peer.presharedKey = nil
    return VStack(alignment: .leading, spacing: 16) {
        PeerSection(config: peer)
    }
    .padding(20)
    .previewEnvironment()
    .frame(width: WindowSizing.ideal.width)
}

#Preview("Standalone — endpoint row") {
    VStack(alignment: .leading, spacing: 16) {
        PeerSection(config: PreviewFixtures.wireguardConfig().wireguard.peer)
    }
    .padding(20)
    .previewEnvironment()
    .frame(width: WindowSizing.ideal.width)
}
