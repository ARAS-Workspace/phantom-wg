import SwiftUI

/// The list's delete selection, in place of `TunnelListSection` while it
/// is open: a row per tunnel, marked by a tap; a row the gate holds
/// (`isSettledInactive`) is dimmed, says why and takes no mark. Its buttons
/// sit in `TunnelDeleteBar` over the list's bottom edge, and the two share
/// a `TunnelDeleteSelection`. The delete the bar asks for is confirmed here
/// with the first names, asks the owner once and goes through
/// `TunnelBulkDelete`; its report goes to `onFinish`. Mac 2.2.1's delete
/// mode is the source; there the buttons sit in the list's header.
struct TunnelDeleteSection: View {
    let rows: [TunnelContainer]
    @Bindable var selection: TunnelDeleteSelection
    let onFinish: (TunnelBulkDelete.Report) -> Void
    let onFailure: (String) -> Void

    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc

    private var targets: [TunnelContainer] {
        TunnelBulkDelete.targets(rows, marked: selection.marked)
    }

    var body: some View {
        Section {
            ForEach(rows) { tunnel in
                row(tunnel)
            }
        } header: {
            Label(loc.t("tunnel_list_section_header"), systemImage: "list.bullet")
                .textCase(nil)
                .padding(.bottom, 6)
        } footer: {
            Text(loc.t("tunnel_list_delete_hint"))
        }
        .confirmationDialog(
            loc.t("tunnel_list_delete_confirm_title", targets.count),
            isPresented: $selection.confirming,
            titleVisibility: .visible
        ) {
            Button(loc.t("delete"), role: .destructive) { run() }
                .accessibilityIdentifier(AXID.TunnelList.deleteConfirm)
            Button(loc.t("cancel"), role: .cancel) {}
                .accessibilityIdentifier(AXID.TunnelList.deleteConfirmCancel)
        } message: {
            Text(TunnelBulkDelete.confirmMessage(targets.map(\.name), loc: loc))
        }
    }

    private func row(_ tunnel: TunnelContainer) -> some View {
        let deletable = tunnel.isSettledInactive
        let isMarked = selection.marked.contains(tunnel.id)
        return HStack(spacing: 12) {
            Image(systemName: isMarked ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isMarked ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                TunnelRow(tunnel: tunnel, showsToggle: false)
                if !deletable {
                    Text(loc.t("tunnel_list_delete_active_note"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard deletable, !selection.running else { return }
            if isMarked {
                selection.marked.remove(tunnel.id)
            } else {
                selection.marked.insert(tunnel.id)
            }
        }
        .opacity(deletable ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isMarked ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(AXID.TunnelList.deleteRow(tunnel.name))
    }

    /// The confirmed delete: the owner is asked once, then the marked rows
    /// go through `TunnelBulkDelete` while the bar counts them.
    private func run() {
        let chosen = targets
        guard !chosen.isEmpty, !selection.running else { return }
        selection.running = true
        Task {
            let granted = await PrivateDataGuard.grants(
                reason: loc.t("delete_tunnels_private_data_reason"),
                onFailure: onFailure
            )
            guard granted else {
                selection.running = false
                return
            }
            selection.progress = TunnelDeleteSelection.Progress(done: 0, total: chosen.count)
            let report = await TunnelBulkDelete.run(chosen, in: tunnelsManager) { done in
                selection.progress = TunnelDeleteSelection.Progress(done: done, total: chosen.count)
            }
            selection.progress = nil
            selection.running = false
            selection.marked = []
            onFinish(report)
        }
    }
}
