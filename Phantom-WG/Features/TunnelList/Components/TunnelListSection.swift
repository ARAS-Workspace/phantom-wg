import SwiftUI

/// The titled section of tunnel rows the list and the search page share:
/// a header with the count, a row per tunnel that opens its detail, and
/// one line naming the query when a search leaves no row. Given `onMove`,
/// a row is dragged after a long press and lands where it is dropped;
/// given `onStep`, VoiceOver offers Move Up and Move Down on each row.
/// A row the gate lets go (`isSettledInactive`) is swiped left to a red
/// delete: once confirmed and granted by the owner it is removed through
/// `TunnelBulkDelete`, which checks the gate again when it runs.
struct TunnelListSection: View {
    let rows: [TunnelContainer]
    /// What the header's capsule shows: every tunnel, or the rows shown
    /// out of every tunnel.
    let count: String
    /// The query a search typed, trimmed; empty outside a search.
    var query = ""
    /// The rows' move after a drag: the offsets dragged and the row they
    /// land before. Nil leaves the rows where they are.
    var onMove: ((IndexSet, Int) -> Void)?
    /// One step of a row up (`true`) or down, from VoiceOver.
    var onStep: ((UUID, Bool) -> Void)?
    /// Opens the delete selection from the header's trash button; nil
    /// draws no button.
    var onSelect: (() -> Void)?

    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc

    /// The swipe's question, then what a delete that did not land says.
    private enum DeleteAlert {
        case confirm(TunnelContainer)
        case failed(String)
    }

    @State private var deleteAlert: DeleteAlert?

    var body: some View {
        Section {
            if rows.isEmpty, !query.isEmpty {
                Text(loc.t("tunnel_list_search_no_match", query))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(AXID.TunnelList.searchNoMatch)
            } else {
                ForEach(rows) { tunnel in
                    NavigationLink(destination: TunnelDetailView(tunnel: tunnel)) {
                        TunnelRow(tunnel: tunnel)
                    }
                    .accessibilityActions {
                        if let onStep {
                            Button(loc.t("tunnel_list_move_up")) { onStep(tunnel.id, true) }
                            Button(loc.t("tunnel_list_move_down")) { onStep(tunnel.id, false) }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if tunnel.isSettledInactive {
                            Button {
                                deleteAlert = .confirm(tunnel)
                            } label: {
                                Label(loc.t("delete"), systemImage: "trash")
                            }
                            .tint(.red)
                            .accessibilityIdentifier(AXID.TunnelList.rowDelete(tunnel.name))
                        }
                    }
                }
                .onMove(perform: onMove)
            }
        } header: {
            HStack {
                Label(loc.t("tunnel_list_section_header"), systemImage: "list.bullet")
                Spacer()
                Text(verbatim: count)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                    )
                    .accessibilityIdentifier(AXID.TunnelList.listCount)
                if let onSelect {
                    Button(action: onSelect) {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(loc.t("tunnel_list_delete"))
                    .accessibilityIdentifier(AXID.TunnelList.deleteButton)
                }
            }
            .padding(.bottom, 6)
        }
        .alert(alertTitle, isPresented: alertShown, presenting: deleteAlert) { alert in
            switch alert {
            case .confirm(let tunnel):
                Button(loc.t("cancel"), role: .cancel) {}
                Button(loc.t("delete"), role: .destructive) { delete(tunnel) }
                    .accessibilityIdentifier(AXID.TunnelList.rowDeleteConfirm)
            case .failed:
                Button(loc.t("ok")) {}
            }
        } message: { alert in
            switch alert {
            case .confirm:
                Text(loc.t("detail_delete_confirm_message"))
            case .failed(let text):
                Text(text)
            }
        }
    }

    private var alertTitle: String {
        switch deleteAlert {
        case .confirm: return loc.t("detail_delete_confirm_title")
        case .failed: return loc.t("error")
        case nil: return ""
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { deleteAlert != nil }, set: { if !$0 { deleteAlert = nil } })
    }

    /// The swipe's delete, once confirmed: the owner is asked, then the
    /// tunnel goes through `TunnelBulkDelete`; what does not land is said.
    private func delete(_ tunnel: TunnelContainer) {
        Task {
            let granted = await PrivateDataGuard.grants(reason: loc.t("delete_private_data_reason")) { message in
                deleteAlert = .failed(message)
            }
            guard granted else { return }
            let report = await TunnelBulkDelete.run([tunnel], in: tunnelsManager)
            if let skipped = report.skipped.first {
                deleteAlert = .failed("\(skipped.name) — \(TunnelBulkDelete.reason(skipped.skip, loc: loc))")
            }
        }
    }
}
