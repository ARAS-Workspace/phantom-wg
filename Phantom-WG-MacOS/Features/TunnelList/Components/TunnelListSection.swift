import SwiftUI

struct TunnelListSection: View {
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc

    @State private var page = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            GeometryReader { geometry in
                let cardHeight = max(
                    TunnelListRules.rowHeight,
                    geometry.size.height - TunnelListRules.pagerHeight - TunnelListRules.pagerGap
                )
                let tunnels = tunnelsManager.tunnels
                let perPage = TunnelListRules.rowsPerPage(height: cardHeight)
                let pages = TunnelListRules.pageCount(itemCount: tunnels.count, perPage: perPage)
                let current = TunnelListRules.clampedPage(page, itemCount: tunnels.count, perPage: perPage)

                VStack(spacing: TunnelListRules.pagerGap) {
                    card(TunnelListRules.page(tunnels, index: current, perPage: perPage), height: cardHeight)
                    pager(current: current, pages: pages)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Label(loc.t("tunnel_list_section_header"), systemImage: "list.bullet")
                .font(.headline)
            Spacer()
            Text(verbatim: "\(tunnelsManager.tunnels.count)")
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
        .padding(.leading, 10)
    }

    private func card(_ tunnels: ArraySlice<TunnelContainer>, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tunnels.enumerated()), id: \.element.id) { index, tunnel in
                if index > 0 {
                    Divider()
                        .padding(.leading, TunnelListRules.dividerInset)
                }
                TunnelListRow(tunnel: tunnel)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .groupedCard()
    }

    private func pager(current: Int, pages: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                page = max(0, current - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(current == 0)
            .help(loc.t("tunnel_list_page_previous"))
            .accessibilityLabel(loc.t("tunnel_list_page_previous"))
            .accessibilityIdentifier(AXID.TunnelList.pagePrevious)

            Text(verbatim: "\(current + 1) / \(pages)")
                .monospacedDigit()
                .frame(minWidth: 56)
                .accessibilityIdentifier(AXID.TunnelList.pageIndicator)

            Button {
                page = min(pages - 1, current + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(current >= pages - 1)
            .help(loc.t("tunnel_list_page_next"))
            .accessibilityLabel(loc.t("tunnel_list_page_next"))
            .accessibilityIdentifier(AXID.TunnelList.pageNext)
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity)
        .frame(height: TunnelListRules.pagerHeight)
    }
}

// MARK: - Previews

#Preview("Three tunnels") {
    NavigationStack {
        TunnelListSection()
            .padding(20)
    }
    .previewEnvironment()
    .frame(width: WindowSizing.ideal.width, height: 480)
}

#Preview("Twenty-five tunnels") {
    NavigationStack {
        TunnelListSection()
            .padding(20)
    }
    .previewEnvironment(tunnels: PreviewFixtures.tunnelsManager(providers: (1...25).map { index in
        PreviewFixtures.provider(config: PreviewFixtures.wireguardConfig(name: "Tunnel \(index)"))
    }))
    .frame(width: WindowSizing.ideal.width, height: 480)
}
