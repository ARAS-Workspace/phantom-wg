import SwiftUI

/// The list's delete selection, in place of `TunnelListSection` while it
/// is open: a row per tunnel, marked by a tap; a row the gate holds
/// (`isSettledInactive`) is dimmed, says why and takes no mark. The header
/// cancels the selection or deletes the marked rows; the footer marks every
/// row the gate lets go, or takes those marks off, and shows the progress
/// while a delete runs. The delete is confirmed with the first names, asks
/// the owner once and goes through `TunnelBulkDelete`; its report goes to
/// `onFinish`. Mac 2.2.1's delete mode is the source.
struct TunnelDeleteSection: View {
    let rows: [TunnelContainer]
    let onFinish: (TunnelBulkDelete.Report) -> Void
    let onCancel: () -> Void
    let onFailure: (String) -> Void

    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc

    /// How far a delete has run: the targets done out of every target.
    private struct Progress {
        let done: Int
        let total: Int
    }

    @State private var marked: Set<UUID> = []
    @State private var confirming = false
    @State private var running = false
    @State private var progress: Progress?

    private var targets: [TunnelContainer] {
        TunnelBulkDelete.targets(rows, marked: marked)
    }

    var body: some View {
        Section {
            ForEach(rows) { tunnel in
                row(tunnel)
            }
        } header: {
            header
        } footer: {
            footer
        }
        .confirmationDialog(
            loc.t("tunnel_list_delete_confirm_title", targets.count),
            isPresented: $confirming,
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
        let isMarked = marked.contains(tunnel.id)
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
            guard deletable, !running else { return }
            if isMarked {
                marked.remove(tunnel.id)
            } else {
                marked.insert(tunnel.id)
            }
        }
        .opacity(deletable ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isMarked ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(AXID.TunnelList.deleteRow(tunnel.name))
    }

    private var header: some View {
        HStack {
            Label(loc.t("tunnel_list_section_header"), systemImage: "list.bullet")
            Spacer()
            Button(loc.t("cancel")) {
                marked = []
                onCancel()
            }
            .disabled(running)
            .accessibilityIdentifier(AXID.TunnelList.deleteCancel)
            Button(loc.t("tunnel_list_delete_marked", targets.count), role: .destructive) {
                confirming = true
            }
            .tint(.red)
            .disabled(targets.isEmpty || running)
            .accessibilityIdentifier(AXID.TunnelList.deleteMarked)
        }
        .textCase(nil)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack {
            Button(loc.t(TunnelBulkDelete.allMarked(marked, rows: rows)
                         ? "tunnel_list_delete_select_none" : "tunnel_list_delete_select_all")) {
                marked = TunnelBulkDelete.toggledAll(marked, rows: rows)
            }
            .disabled(!rows.contains(where: \.isSettledInactive) || running)
            .accessibilityIdentifier(AXID.TunnelList.deleteSelectAll)
            Spacer()
            if let progress {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(loc.t("tunnel_list_deleting", progress.done, progress.total))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AXID.TunnelList.deleteProgress)
            } else {
                Text(loc.t("tunnel_list_delete_hint"))
            }
        }
        .font(.footnote)
    }

    /// The confirmed delete: the owner is asked once, then the marked rows
    /// go through `TunnelBulkDelete` while the footer counts them.
    private func run() {
        let chosen = targets
        guard !chosen.isEmpty, !running else { return }
        running = true
        Task {
            let granted = await PrivateDataGuard.grants(
                reason: loc.t("delete_tunnels_private_data_reason"),
                onFailure: onFailure
            )
            guard granted else {
                running = false
                return
            }
            progress = Progress(done: 0, total: chosen.count)
            let report = await TunnelBulkDelete.run(chosen, in: tunnelsManager) { done in
                progress = Progress(done: done, total: chosen.count)
            }
            progress = nil
            running = false
            marked = []
            onFinish(report)
        }
    }
}
