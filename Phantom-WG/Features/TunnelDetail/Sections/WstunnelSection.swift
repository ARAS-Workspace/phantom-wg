import SwiftUI

/// Ghost-mode section, read-only — only present when
/// `TunnelConfig.wstunnel` is non-nil. Shows the six wstunnel bridge
/// fields; adding, changing, or removing the bridge happens in
/// `TunnelEditView`'s raw-text editor.
struct WstunnelSection: View {
    let config: WstunnelConfig
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            PhantomStaticField(
                label: loc.t("detail_server_url"),
                value: config.url.textual,
                axIdentifier: AXID.TunnelDetail.Wstunnel.url
            )
            PhantomStaticField(
                label: loc.t("detail_secret"),
                value: config.secret,
                axIdentifier: AXID.TunnelDetail.Wstunnel.secret
            )
            PhantomStaticField(
                label: loc.t("detail_local_host"),
                value: config.localHost,
                axIdentifier: AXID.TunnelDetail.Wstunnel.localHost
            )
            PhantomStaticField(
                label: loc.t("detail_local_port"),
                value: String(config.localPort),
                axIdentifier: AXID.TunnelDetail.Wstunnel.localPort
            )
            PhantomStaticField(
                label: loc.t("detail_remote_host"),
                value: config.remoteHost,
                axIdentifier: AXID.TunnelDetail.Wstunnel.remoteHost
            )
            PhantomStaticField(
                label: loc.t("detail_remote_port"),
                value: String(config.remotePort),
                axIdentifier: AXID.TunnelDetail.Wstunnel.remotePort
            )
        } header: {
            Label(loc.t("detail_wstunnel"), systemImage: "network.badge.shield.half.filled")
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    Form {
        WstunnelSection(config: PreviewFixtures.ghostConfig().wstunnel!)
    }
    .formStyle(.grouped)
    .previewEnvironment(scheme: .light)
}

#Preview("Dark") {
    Form {
        WstunnelSection(config: PreviewFixtures.ghostConfig().wstunnel!)
    }
    .formStyle(.grouped)
    .previewEnvironment(scheme: .dark)
}
