import SwiftUI

struct TunnelListSection: View {
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc

    @State private var page = 0
    @State private var query = ""

    private var filtered: [TunnelContainer] {
        tunnelsManager.tunnels.filter { TunnelListRules.matches($0.name, query: query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            TunnelSearchField(text: $query, placeholder: loc.t("tunnel_list_search_placeholder"))
                .frame(height: 24)

            GeometryReader { geometry in
                let cardHeight = max(
                    TunnelListRules.rowHeight,
                    geometry.size.height - TunnelListRules.pagerHeight - TunnelListRules.pagerGap
                )
                let tunnels = filtered
                let perPage = TunnelListRules.rowsPerPage(height: cardHeight)
                let pages = TunnelListRules.pageCount(itemCount: tunnels.count, perPage: perPage)
                let current = TunnelListRules.clampedPage(page, itemCount: tunnels.count, perPage: perPage)

                VStack(spacing: TunnelListRules.pagerGap) {
                    if tunnels.isEmpty {
                        noMatch(height: cardHeight)
                    } else {
                        card(TunnelListRules.page(tunnels, index: current, perPage: perPage), height: cardHeight)
                    }
                    pager(current: current, pages: pages)
                }
            }
        }
        .onChange(of: query) { _, _ in page = 0 }
    }

    private var countText: String {
        let total = tunnelsManager.tunnels.count
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(total)" : "\(filtered.count) / \(total)"
    }

    private func noMatch(height: CGFloat) -> some View {
        Text(loc.t("tunnel_list_search_no_match", query.trimmingCharacters(in: .whitespacesAndNewlines)))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .groupedCard()
            .accessibilityIdentifier(AXID.TunnelList.searchNoMatch)
    }

    private var header: some View {
        HStack {
            Label(loc.t("tunnel_list_section_header"), systemImage: "list.bullet")
                .font(.headline)
            Spacer()
            Text(verbatim: countText)
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
                        .padding(.horizontal, TunnelListRules.dividerInset)
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
