import SwiftUI

struct TunnelListSection: View {
    var onDeleteReport: (TunnelBulkDelete.Report) -> Void = { _ in }
    var onDeleteError: (String) -> Void = { _ in }

    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc

    private enum Mode {
        case browsing, reordering, deleting
    }

    @State private var page = 0
    @State private var query = ""
    @State private var savedOrder = TunnelListOrderStore.load()
    @State private var mode = Mode.browsing
    @State private var draft: [UUID] = []
    @State private var marked: Set<UUID> = []
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var progress: (done: Int, total: Int)?

    private var ordered: [TunnelContainer] {
        TunnelListRules.ordered(tunnelsManager.tunnels, saved: savedOrder, id: \.id)
    }

    private var filtered: [TunnelContainer] {
        ordered.filter { TunnelListRules.matches($0.name, query: query) }
    }

    private var targets: [TunnelContainer] {
        TunnelBulkDelete.targets(ordered, marked: marked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            TunnelSearchField(text: $query, placeholder: loc.t("tunnel_list_search_placeholder"), enabled: mode != .reordering)
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
                    switch mode {
                    case .reordering:
                        TunnelReorderCard(tunnels: tunnelsManager.tunnels, draft: $draft)
                            .frame(height: cardHeight)
                        hint(loc.t("tunnel_list_reorder_hint"))
                    case .deleting:
                        if tunnels.isEmpty {
                            noMatch(height: cardHeight)
                        } else {
                            TunnelDeleteCard(tunnels: tunnels, marked: $marked, enabled: !deleting)
                                .frame(height: cardHeight)
                        }
                        deleteFooter
                    case .browsing:
                        if tunnels.isEmpty {
                            noMatch(height: cardHeight)
                        } else {
                            card(TunnelListRules.page(tunnels, index: current, perPage: perPage), height: cardHeight)
                        }
                        pager(current: current, pages: pages)
                    }
                }
            }
        }
        .onChange(of: query) { _, _ in page = 0 }
        .confirmationDialog(
            loc.t("tunnel_list_delete_confirm_title", targets.count),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(loc.t("delete"), role: .destructive) { runDelete() }
                .accessibilityIdentifier(AXID.TunnelList.deleteConfirm)
            Button(loc.t("cancel"), role: .cancel) {}
                .accessibilityIdentifier(AXID.TunnelList.deleteConfirmCancel)
        } message: {
            Text(TunnelBulkDelete.confirmMessage(targets.map(\.name), loc: loc))
        }
    }

    private var countText: String {
        let total = tunnelsManager.tunnels.count
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(total)" : "\(filtered.count) / \(total)"
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: TunnelListRules.pagerHeight)
    }

    private var deleteFooter: some View {
        let eligible = Set(filtered.filter(\.isSettledInactive).map(\.id))
        let allMarked = !eligible.isEmpty && eligible.isSubset(of: marked)
        return HStack {
            Button(loc.t(allMarked ? "tunnel_list_delete_select_none" : "tunnel_list_delete_select_all")) {
                if allMarked {
                    marked.subtract(eligible)
                } else {
                    marked.formUnion(eligible)
                }
            }
            .buttonStyle(.borderless)
            .disabled(eligible.isEmpty || deleting)
            .accessibilityIdentifier(AXID.TunnelList.deleteSelectAll)
            Spacer()
            if let progress {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(loc.t("tunnel_list_deleting", progress.done, progress.total))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AXID.TunnelList.deleteProgress)
            } else {
                Text(loc.t("tunnel_list_delete_hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: TunnelListRules.pagerHeight)
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
            modeControls
        }
        .padding(.leading, 10)
    }

    @ViewBuilder
    private var modeControls: some View {
        switch mode {
        case .reordering:
            Button(loc.t("cancel")) {
                draft = []
                mode = .browsing
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier(AXID.TunnelList.reorderCancel)

            Button(loc.t("tunnel_list_reorder_done")) {
                savedOrder = draft
                TunnelListOrderStore.save(draft)
                draft = []
                mode = .browsing
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(AXID.TunnelList.reorderDone)
        case .deleting:
            Button(loc.t("cancel")) {
                marked = []
                query = ""
                mode = .browsing
            }
            .keyboardShortcut(.cancelAction)
            .disabled(deleting)
            .accessibilityIdentifier(AXID.TunnelList.deleteCancel)

            Button(loc.t("tunnel_list_delete_marked", targets.count), role: .destructive) {
                confirmingDelete = true
            }
            .tint(.red)
            .disabled(targets.isEmpty || deleting)
            .accessibilityIdentifier(AXID.TunnelList.deleteMarked)
        case .browsing:
            Button {
                query = ""
                page = 0
                draft = ordered.map(\.id)
                mode = .reordering
            } label: {
                Label(loc.t("tunnel_list_reorder"), systemImage: "arrow.up.arrow.down")
            }
            .disabled(tunnelsManager.tunnels.count < 2)
            .accessibilityIdentifier(AXID.TunnelList.reorderButton)

            Button {
                query = ""
                page = 0
                marked = []
                mode = .deleting
            } label: {
                Label(loc.t("tunnel_list_delete"), systemImage: "trash")
            }
            .disabled(tunnelsManager.tunnels.isEmpty)
            .accessibilityIdentifier(AXID.TunnelList.deleteButton)
        }
    }

    private func runDelete() {
        guard !targets.isEmpty, !deleting else { return }
        deleting = true
        Task {
            let granted = await PrivateDataGuard.grants(
                reason: loc.t("delete_tunnels_private_data_reason"),
                onFailure: onDeleteError
            )
            guard granted else {
                deleting = false
                return
            }
            let chosen = targets
            progress = (0, chosen.count)
            let report = await TunnelBulkDelete.run(chosen, in: tunnelsManager) { done in
                progress = (done, chosen.count)
            }
            progress = nil
            deleting = false
            marked = []
            query = ""
            mode = .browsing
            onDeleteReport(report)
        }
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
