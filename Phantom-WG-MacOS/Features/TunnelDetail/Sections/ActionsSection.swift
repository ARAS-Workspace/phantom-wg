import SwiftUI

/// Footer actions — copy-to-clipboard, reset connection, and delete.
///
/// - Copy owns its own "Copied!" feedback timer locally.
/// - Reset is enabled only while the tunnel is active/reasserting;
///   tapping it asks the extension to restart the tunnel layer in
///   place (wstunnel + WireGuard in ghost mode, WireGuard alone in
///   standalone) without touching utun — so no packet escapes to the
///   physical interface during the reset window.
/// - Delete is routed back to the parent's confirmation dialog via a
///   binding so the destructive action lives at the view root.
struct ActionsSection: View {
    var tunnel: TunnelContainer
    let copyAction: () -> Void
    let resetAction: () -> Void
    @Binding var showingDeleteConfirmation: Bool
    @State private var copiedItem: String?
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            copyButton(loc.t("detail_copy_conf"), icon: "doc.text", id: "conf") { copyAction() }
                .listRowSeparator(.hidden)
                .accessibilityIdentifier(AXID.TunnelDetail.Actions.copyButton)

            Button(action: resetAction) {
                Label(loc.t("detail_reset_connection"), systemImage: "arrow.clockwise")
            }
            .disabled(!canReset)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier(AXID.TunnelDetail.Actions.resetButton)

            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label(loc.t("detail_delete_tunnel"), systemImage: "trash")
            }
            .disabled(tunnel.status != .inactive)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier(AXID.TunnelDetail.Actions.deleteButton)
        } header: {
            Label(loc.t("detail_actions"), systemImage: "ellipsis.circle")
        }
    }

    /// Reset only applies when the extension is holding the tunnel
    /// surface. Inactive / deactivating states have no utun to
    /// preserve; the button collapses to disabled.
    private var canReset: Bool {
        tunnel.status == .active || tunnel.status == .reasserting
    }

    private func copyButton(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            copiedItem = id
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copiedItem == id { copiedItem = nil }
            }
        } label: {
            Label(copiedItem == id ? loc.t("detail_copied") : title,
                  systemImage: copiedItem == id ? "checkmark.circle.fill" : icon)
            .foregroundStyle(copiedItem == id ? .green : .accentColor)
        }
    }
}

// MARK: - Previews

#Preview("Active — reset enabled") {
    let manager = PreviewFixtures.tunnelsManager()
    return PreviewBindingHost(false) { showingDelete in
        List {
            ActionsSection(
                tunnel: manager.tunnels[0],
                copyAction: {},
                resetAction: {},
                showingDeleteConfirmation: showingDelete
            )
        }
    }
    .previewEnvironment(tunnels: manager)
    .frame(width: 480)
}

#Preview("Inactive — delete enabled") {
    let manager = PreviewFixtures.tunnelsManager()
    return PreviewBindingHost(false) { showingDelete in
        List {
            ActionsSection(
                tunnel: manager.tunnels[1],
                copyAction: {},
                resetAction: {},
                showingDeleteConfirmation: showingDelete
            )
        }
    }
    .previewEnvironment(tunnels: manager)
    .frame(width: 480)
}
