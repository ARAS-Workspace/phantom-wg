import SwiftUI

/// WireGuard peer configuration — public/preshared keys, allowed IPs,
/// endpoint, and keepalive. Editable only while the tunnel is inactive.
struct PeerSection: View {
    @Binding var draft: PeerDraft
    let isEditable: Bool
    let fieldErrors: [TunnelDraft.Field: FieldValidationError]
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            PhantomTextField(
                label: loc.t("detail_public_key"),
                text: $draft.publicKey,
                isDisabled: !isEditable,
                errorMessage: fieldErrors[.peerPublicKey]?.localizedMessage(loc),
                axIdentifier: AXID.TunnelDetail.Peer.publicKey
            )
            PhantomTextField(
                label: loc.t("detail_preshared_key"),
                text: $draft.presharedKey,
                isDisabled: !isEditable,
                errorMessage: fieldErrors[.peerPresharedKey]?.localizedMessage(loc),
                axIdentifier: AXID.TunnelDetail.Peer.presharedKey
            )
            PhantomTextField(
                label: loc.t("detail_allowed_ips"),
                text: $draft.allowedIPs,
                isDisabled: !isEditable,
                errorMessage: fieldErrors[.peerAllowedIPs]?.localizedMessage(loc),
                axIdentifier: AXID.TunnelDetail.Peer.allowedIPs
            )
            PhantomTextField(
                label: loc.t("detail_endpoint"),
                text: $draft.endpoint,
                isDisabled: !isEditable,
                errorMessage: fieldErrors[.peerEndpoint]?.localizedMessage(loc),
                axIdentifier: AXID.TunnelDetail.Peer.endpoint
            )
            PhantomStringNumericField(
                label: loc.t("detail_keepalive"),
                text: $draft.persistentKeepalive,
                isDisabled: !isEditable,
                errorMessage: fieldErrors[.peerPersistentKeepalive]?.localizedMessage(loc),
                axIdentifier: AXID.TunnelDetail.Peer.keepalive
            )
        } header: {
            Label(loc.t("detail_peer"), systemImage: "point.3.connected.trianglepath.dotted")
        }
    }
}

// MARK: - Previews

#Preview("Editable") {
    PreviewBindingHost(PeerDraft(from: PreviewFixtures.ghostConfig().wireguard.peer)) { draft in
        List {
            PeerSection(draft: draft, isEditable: true, fieldErrors: [:])
        }
    }
    .previewEnvironment()
    .frame(width: 480)
}

#Preview("Field error") {
    PreviewBindingHost(PeerDraft(from: PreviewFixtures.ghostConfig().wireguard.peer)) { draft in
        List {
            PeerSection(
                draft: draft,
                isEditable: true,
                fieldErrors: [.peerPublicKey: .wireGuardKey(.notBase64)]
            )
        }
    }
    .previewEnvironment()
    .frame(width: 480)
}
