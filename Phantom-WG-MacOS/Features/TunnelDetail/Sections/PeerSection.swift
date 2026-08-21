import SwiftUI

struct PeerSection: View {
    let config: PeerConfig
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            PhantomStaticField(
                label: loc.t("detail_public_key"),
                value: config.publicKey.textual,
                axIdentifier: AXID.TunnelDetail.Peer.publicKey
            )
            if let preshared = config.presharedKey {
                PhantomStaticField(
                    label: loc.t("detail_preshared_key"),
                    value: preshared.textual,
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
                value: String(config.persistentKeepalive),
                axIdentifier: AXID.TunnelDetail.Peer.keepalive
            )
        } header: {
            Label(loc.t("detail_peer"), systemImage: "point.3.connected.trianglepath.dotted")
        }
    }
}

// MARK: - Previews

#Preview("With preshared key") {
    Form {
        PeerSection(config: PreviewFixtures.ghostConfig().wireguard.peer)
    }
    .formStyle(.grouped)
    .previewEnvironment()
    .frame(width: 560)
}

#Preview("Without preshared key") {
    var peer = PreviewFixtures.ghostConfig().wireguard.peer
    peer.presharedKey = nil
    return Form {
        PeerSection(config: peer)
    }
    .formStyle(.grouped)
    .previewEnvironment()
    .frame(width: 560)
}

#Preview("Standalone — endpoint row") {
    Form {
        PeerSection(config: PreviewFixtures.wireguardConfig().wireguard.peer)
    }
    .formStyle(.grouped)
    .previewEnvironment()
    .frame(width: 560)
}
