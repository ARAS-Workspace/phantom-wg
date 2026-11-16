import SwiftUI

struct TunnelDeleteCard: View {
    let tunnels: [TunnelContainer]
    @Binding var marked: Set<UUID>
    let enabled: Bool
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(tunnels.enumerated()), id: \.element.id) { index, tunnel in
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
        .disabled(!enabled)
    }

    private func row(_ tunnel: TunnelContainer) -> some View {
        let deletable = tunnel.isSettledInactive
        let isMarked = marked.contains(tunnel.id)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isMarked },
                set: { mark(tunnel.id, $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!deletable)
            .frame(width: 16)
            TunnelRow(tunnel: tunnel, showsToggle: false)
        }
        .padding(.horizontal, 10)
        .frame(height: TunnelListRules.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            if deletable { mark(tunnel.id, !isMarked) }
        }
        .opacity(deletable ? 1 : 0.45)
        .help(deletable ? "" : loc.t("tunnel_list_delete_active_note"))
        .accessibilityIdentifier(AXID.TunnelList.deleteRow(tunnel.name))
    }

    private func mark(_ id: UUID, _ on: Bool) {
        if on {
            marked.insert(id)
        } else {
            marked.remove(id)
        }
    }
}

// MARK: - Previews

#Preview("Deleting") {
    let manager = PreviewFixtures.tunnelsManager()
    return TunnelDeleteCard(tunnels: manager.tunnels, marked: .constant([manager.tunnels[1].id]), enabled: true)
        .frame(height: 240)
        .padding(20)
        .previewEnvironment(tunnels: manager)
        .frame(width: WindowSizing.ideal.width)
}
