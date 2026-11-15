import SwiftUI
import UniformTypeIdentifiers

struct TunnelReorderCard: View {
    let tunnels: [TunnelContainer]
    @Binding var draft: [UUID]
    @Environment(LocalizationManager.self) private var loc

    @State private var dragging: UUID?

    private var rows: [TunnelContainer] {
        let byId = Dictionary(tunnels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return draft.compactMap { byId[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, tunnel in
                    if index > 0 {
                        Divider()
                            .padding(.horizontal, TunnelListRules.dividerInset)
                    }
                    row(tunnel)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .groupedCard()
        .onDrop(of: [UTType.text], delegate: AreaDrop(dragging: $dragging))
    }

    private func row(_ tunnel: TunnelContainer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            TunnelRow(tunnel: tunnel, showsToggle: false)
        }
        .padding(.horizontal, 10)
        .frame(height: TunnelListRules.rowHeight)
        .contentShape(Rectangle())
        .opacity(dragging == tunnel.id ? 0.35 : 1)
        .onDrag {
            dragging = tunnel.id
            return NSItemProvider(object: tunnel.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text], delegate: RowDrop(target: tunnel.id, draft: $draft, dragging: $dragging))
        .contextMenu { moveMenu(tunnel.id) }
        .accessibilityAction(named: Text(loc.t("tunnel_list_move_up"))) { move(tunnel.id, up: true) }
        .accessibilityAction(named: Text(loc.t("tunnel_list_move_down"))) { move(tunnel.id, up: false) }
        .accessibilityIdentifier(AXID.TunnelList.reorderRow(tunnel.name))
    }

    @ViewBuilder
    private func moveMenu(_ id: UUID) -> some View {
        Button(loc.t("tunnel_list_move_top")) {
            withAnimation { draft = TunnelListRules.movedToEdge(draft, id, top: true) }
        }
        Button(loc.t("tunnel_list_move_up")) { move(id, up: true) }
        Button(loc.t("tunnel_list_move_down")) { move(id, up: false) }
        Button(loc.t("tunnel_list_move_bottom")) {
            withAnimation { draft = TunnelListRules.movedToEdge(draft, id, top: false) }
        }
    }

    private func move(_ id: UUID, up: Bool) {
        withAnimation { draft = TunnelListRules.movedByOne(draft, id, up: up) }
    }
}

private struct RowDrop: DropDelegate {
    let target: UUID
    @Binding var draft: [UUID]
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let moving = dragging, moving != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            draft = TunnelListRules.moving(draft, moving, onto: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct AreaDrop: DropDelegate {
    @Binding var dragging: UUID?

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - Previews

#Preview("Reordering") {
    let manager = PreviewFixtures.tunnelsManager()
    return TunnelReorderCard(tunnels: manager.tunnels, draft: .constant(manager.tunnels.map(\.id)))
        .frame(height: 240)
        .padding(20)
        .previewEnvironment(tunnels: manager)
        .frame(width: WindowSizing.ideal.width)
}
