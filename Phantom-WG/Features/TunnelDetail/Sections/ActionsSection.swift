import SwiftUI

/// Footer actions — copy-to-clipboard, export, edit, reset connection,
/// and delete.
///
/// - Copy, export, edit, and delete reach the tunnel's private data, so
///   each asks the device owner first (`PrivateDataGuard`, in the
///   parent's actions).
/// - Export hands the `.conf` file to the system's export picker, where
///   the user picks the place it is saved.
/// - Copy owns its own "Copied!" feedback timer locally and shows it
///   only when something was copied.
/// - Edit opens `TunnelEditView` (raw-text editing, the WireGuard app
///   pattern) and is enabled only while the tunnel is inactive.
/// - Reset is enabled only while the tunnel is active/reasserting;
///   tapping it asks the extension to restart the tunnel layer in
///   place (wstunnel + WireGuard in ghost mode, WireGuard alone in
///   standalone) without touching utun — so no packet escapes to the
///   physical interface during the reset window. It stays down while
///   one is in flight: the extension answers a second request with the
///   first one's outcome, so a second tap could only ever repeat an
///   answer the user is still waiting for.
/// - Delete is routed back to the parent's confirmation dialog via a
///   binding so the destructive action lives at the view root. It
///   stays down while a removal is in flight.
struct ActionsSection: View {
    var tunnel: TunnelContainer
    let canCopy: Bool
    let copyAction: () async -> Bool
    let exportAction: () -> Void
    let editAction: () -> Void
    let resetAction: () -> Void
    let resetting: Bool
    let deleting: Bool
    @Binding var showingDeleteConfirmation: Bool
    @State private var copiedItem: String?
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            copyButton(loc.t("detail_copy_conf"), icon: "doc.text", id: "conf", action: copyAction)
                .disabled(!canCopy)
                .accessibilityIdentifier(AXID.TunnelDetail.Actions.copyButton)

            Button(action: exportAction) {
                Label(loc.t("detail_export_conf"), systemImage: "square.and.arrow.up")
            }
            .disabled(!canCopy)
            .accessibilityIdentifier(AXID.TunnelDetail.Actions.exportButton)

            Button(action: editAction) {
                Label(loc.t("detail_edit_conf"), systemImage: "square.and.pencil")
            }
            .disabled(!canEdit)
            .accessibilityIdentifier(AXID.TunnelDetail.Actions.editButton)

            Button(action: resetAction) {
                Label(loc.t("detail_reset_connection"), systemImage: "arrow.clockwise")
            }
            .disabled(!canReset || resetting)
            .accessibilityIdentifier(AXID.TunnelDetail.Actions.resetButton)

            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label(loc.t("detail_delete_tunnel"), systemImage: "trash")
            }
            .disabled(tunnel.status != .inactive || deleting)
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

    /// Config edits require a fully stopped tunnel — mirrors the
    /// delete gate.
    private var canEdit: Bool {
        tunnel.status == .inactive
    }

    private func copyButton(_ title: String, icon: String, id: String, action: @escaping () async -> Bool) -> some View {
        Button {
            Task {
                guard await action() else { return }
                copiedItem = id
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

#Preview("Active — Light") {
    let manager = PreviewFixtures.tunnelsManager()
    return PreviewBindingHost(false) { showingDelete in
        Form {
            ActionsSection(
                tunnel: manager.tunnels[0],
                canCopy: true,
                copyAction: { true },
                exportAction: {},
                editAction: {},
                resetAction: {},
                resetting: false,
                deleting: false,
                showingDeleteConfirmation: showingDelete
            )
        }
        .formStyle(.grouped)
    }
    .previewEnvironment(tunnels: manager, scheme: .light)
}

#Preview("Active — Dark") {
    let manager = PreviewFixtures.tunnelsManager()
    return PreviewBindingHost(false) { showingDelete in
        Form {
            ActionsSection(
                tunnel: manager.tunnels[0],
                canCopy: true,
                copyAction: { true },
                exportAction: {},
                editAction: {},
                resetAction: {},
                resetting: false,
                deleting: false,
                showingDeleteConfirmation: showingDelete
            )
        }
        .formStyle(.grouped)
    }
    .previewEnvironment(tunnels: manager, scheme: .dark)
}

#Preview("Inactive — delete enabled") {
    let manager = PreviewFixtures.tunnelsManager()
    return PreviewBindingHost(false) { showingDelete in
        Form {
            ActionsSection(
                tunnel: manager.tunnels[1],
                canCopy: true,
                copyAction: { true },
                exportAction: {},
                editAction: {},
                resetAction: {},
                resetting: false,
                deleting: false,
                showingDeleteConfirmation: showingDelete
            )
        }
        .formStyle(.grouped)
    }
    .previewEnvironment(tunnels: manager)
}
