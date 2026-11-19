import SwiftUI

/// The titled section of tunnel rows the list and the search page share:
/// a header with the count, a row per tunnel that opens its detail, and
/// one line naming the query when a search leaves no row. Given `onMove`,
/// a row is dragged after a long press and lands where it is dropped;
/// given `onStep`, VoiceOver offers Move Up and Move Down on each row.
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

    @Environment(LocalizationManager.self) private var loc

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
            }
            .padding(.bottom, 6)
        }
    }
}
