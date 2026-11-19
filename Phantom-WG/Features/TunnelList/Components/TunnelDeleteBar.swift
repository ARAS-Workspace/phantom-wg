import SwiftUI

/// The delete selection's buttons, held over the list's bottom edge while
/// the selection is open so a long list scrolls under them, drawn as the
/// search page draws its field: a round Cancel; Select All, which marks
/// every row the gate lets go or takes those marks off, and gives its place
/// to the progress while a delete runs; and a trash button with the marked
/// count, which asks `TunnelDeleteSection` for the confirmation. VoiceOver
/// reads Cancel and Delete with the count.
struct TunnelDeleteBar: View {
    let rows: [TunnelContainer]
    let selection: TunnelDeleteSelection
    let onCancel: () -> Void

    @Environment(LocalizationManager.self) private var loc

    private var count: Int {
        TunnelBulkDelete.targets(rows, marked: selection.marked).count
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(selection.running)
            .accessibilityLabel(loc.t("cancel"))
            .accessibilityIdentifier(AXID.TunnelList.deleteCancel)

            Spacer(minLength: 0)
            middle
            Spacer(minLength: 0)

            let deletable = count > 0 && !selection.running
            Button {
                selection.confirming = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text(verbatim: "\(count)")
                        .monospacedDigit()
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(.regularMaterial, in: Capsule())
                .opacity(deletable ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!deletable)
            .accessibilityLabel(loc.t("tunnel_list_delete_marked", count))
            .accessibilityIdentifier(AXID.TunnelList.deleteMarked)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var middle: some View {
        if let progress = selection.progress {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(loc.t("tunnel_list_deleting", progress.done, progress.total))
                    .font(.footnote)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(.regularMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AXID.TunnelList.deleteProgress)
        } else {
            let selectable = rows.contains(where: \.isSettledInactive) && !selection.running
            Button {
                selection.marked = TunnelBulkDelete.toggledAll(selection.marked, rows: rows)
            } label: {
                Text(loc.t(TunnelBulkDelete.allMarked(selection.marked, rows: rows)
                           ? "tunnel_list_delete_select_none" : "tunnel_list_delete_select_all"))
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(.regularMaterial, in: Capsule())
                    .opacity(selectable ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!selectable)
            .accessibilityIdentifier(AXID.TunnelList.deleteSelectAll)
        }
    }
}
