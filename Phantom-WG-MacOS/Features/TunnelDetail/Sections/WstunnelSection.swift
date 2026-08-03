import SwiftUI

/// Ghost-mode section — only present when `TunnelConfig.wstunnel` is
/// non-nil. Exposes the six wstunnel bridge fields; fields remain
/// editable only while the tunnel is inactive.
struct WstunnelSection: View {
    @Binding var draft: WstunnelDraft
    let isEditable: Bool
    let fieldErrors: [TunnelDraft.Field: FieldValidationError]
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            PhantomTextField(
                label: loc.t("detail_server_url"),
                text: $draft.url,
                isDisabled: !isEditable,
                errorMessage: fieldErrors[.wstunnelUrl]?.localizedMessage(loc),
                axIdentifier: AXID.TunnelDetail.Wstunnel.url
            )
            PhantomTextField(
                label: loc.t("detail_secret"),
                text: $draft.secret,
                isDisabled: !isEditable,
                errorMessage: fieldErrors[.wstunnelSecret]?.localizedMessage(loc),
                axIdentifier: AXID.TunnelDetail.Wstunnel.secret
            )
            PhantomTextField(
                label: loc.t("detail_local_host"),
                text: $draft.localHost,
                isDisabled: !isEditable,
                errorMessage: fieldErrors[.wstunnelLocalHost]?.localizedMessage(loc),
                axIdentifier: AXID.TunnelDetail.Wstunnel.localHost
            )
            PhantomStringNumericField(
                label: loc.t("detail_local_port"),
                text: $draft.localPort,
                isDisabled: !isEditable,
                errorMessage: fieldErrors[.wstunnelLocalPort]?.localizedMessage(loc),
                axIdentifier: AXID.TunnelDetail.Wstunnel.localPort
            )
            PhantomTextField(
                label: loc.t("detail_remote_host"),
                text: $draft.remoteHost,
                isDisabled: !isEditable,
                errorMessage: fieldErrors[.wstunnelRemoteHost]?.localizedMessage(loc),
                axIdentifier: AXID.TunnelDetail.Wstunnel.remoteHost
            )
            PhantomStringNumericField(
                label: loc.t("detail_remote_port"),
                text: $draft.remotePort,
                isDisabled: !isEditable,
                errorMessage: fieldErrors[.wstunnelRemotePort]?.localizedMessage(loc),
                axIdentifier: AXID.TunnelDetail.Wstunnel.remotePort
            )
        } header: {
            Label(loc.t("detail_wstunnel"), systemImage: "network.badge.shield.half.filled")
        }
    }
}

// MARK: - Previews

#Preview("Editable") {
    let config = PreviewFixtures.ghostConfig()
    return PreviewBindingHost(WstunnelDraft(from: config.wstunnel!)) { draft in
        List {
            WstunnelSection(draft: draft, isEditable: true, fieldErrors: [:])
        }
    }
    .previewEnvironment()
    .frame(width: 480)
}

#Preview("Field error") {
    let config = PreviewFixtures.ghostConfig()
    return PreviewBindingHost(WstunnelDraft(from: config.wstunnel!)) { draft in
        List {
            WstunnelSection(
                draft: draft,
                isEditable: true,
                fieldErrors: [.wstunnelUrl: .wstunnelURL(.invalidScheme("https"))]
            )
        }
    }
    .previewEnvironment()
    .frame(width: 480)
}
