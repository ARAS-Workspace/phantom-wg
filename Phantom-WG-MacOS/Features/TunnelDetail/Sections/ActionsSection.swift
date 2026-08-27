import SwiftUI

struct ActionsSection: View {
    var tunnel: TunnelContainer
    let canCopy: Bool
    let copyAction: () -> Void
    let editAction: () -> Void
    let resetAction: () -> Void
    let resetting: Bool
    let deleting: Bool
    @Binding var showingDeleteConfirmation: Bool
    @State private var copiedItem: String?
    @State private var copyFeedbackTask: Task<Void, Never>?
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Section {
            copyButton(loc.t("detail_copy_conf"), icon: "doc.text", id: "conf") { copyAction() }
                .disabled(!canCopy)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier(AXID.TunnelDetail.Actions.copyButton)

            Button(action: editAction) {
                Label(loc.t("detail_edit_conf"), systemImage: "square.and.pencil")
            }
            .disabled(!canEdit)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier(AXID.TunnelDetail.Actions.editButton)

            Button(action: resetAction) {
                Label(loc.t("detail_reset_connection"), systemImage: "arrow.clockwise")
            }
            .disabled(!canReset || resetting)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier(AXID.TunnelDetail.Actions.resetButton)

            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label(loc.t("detail_delete_tunnel"), systemImage: "trash")
            }
            .disabled(!tunnel.isSettledInactive || deleting)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier(AXID.TunnelDetail.Actions.deleteButton)
        } header: {
            Label(loc.t("detail_actions"), systemImage: "ellipsis.circle")
        }
    }

    private var canReset: Bool {
        tunnel.status == .active || tunnel.status == .reasserting
    }

    private var canEdit: Bool {
        tunnel.isSettledInactive
    }

    private func copyButton(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            copiedItem = id
            copyFeedbackTask?.cancel()
            copyFeedbackTask = Task {
                guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                copiedItem = nil
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
        Form {
            ActionsSection(
                tunnel: manager.tunnels[0],
                canCopy: true,
                copyAction: {},
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
    .frame(width: 560)
}

#Preview("Inactive — delete enabled") {
    let manager = PreviewFixtures.tunnelsManager()
    return PreviewBindingHost(false) { showingDelete in
        Form {
            ActionsSection(
                tunnel: manager.tunnels[1],
                canCopy: true,
                copyAction: {},
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
    .frame(width: 560)
}
