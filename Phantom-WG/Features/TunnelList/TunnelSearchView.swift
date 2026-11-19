import SwiftUI

/// The tunnel list's search page: the list alone, without the active
/// section, under a search field that sits above the keyboard, as the
/// system's own search opens. The field takes focus when the page first
/// opens; a row opens the tunnel's detail as the list does, and coming back
/// from it finds the query as it was and the keyboard closed. The round
/// close button beside the field goes back to the list. The rows are read
/// with `TunnelListRules.matches`.
struct TunnelSearchView: View {
    @Environment(TunnelsManager.self) private var tunnelsManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @FocusState private var fieldFocused: Bool
    @State private var opened = false

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rows: [TunnelContainer] {
        tunnelsManager.tunnels.filter { TunnelListRules.matches($0.name, query: query) }
    }

    var body: some View {
        let rows = rows
        let total = tunnelsManager.tunnels.count
        Form {
            TunnelListSection(
                rows: rows,
                count: trimmedQuery.isEmpty ? "\(total)" : "\(rows.count) / \(total)",
                query: trimmedQuery
            )
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { searchBar }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            guard !opened else { return }
            opened = true
            fieldFocused = true
        }
        .onChange(of: tunnelsManager.tunnels.isEmpty) { _, empty in
            if empty { dismiss() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(loc.t("tunnel_list_search_placeholder"), text: $query)
                    .focused($fieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { fieldFocused = false }
                    .accessibilityIdentifier(AXID.TunnelSearch.field)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(loc.t("tunnel_list_search_clear"))
                    .accessibilityIdentifier(AXID.TunnelSearch.clear)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.regularMaterial, in: Capsule())

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc.t("cancel"))
            .accessibilityIdentifier(AXID.TunnelSearch.close)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
