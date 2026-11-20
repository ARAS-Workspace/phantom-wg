import Foundation

/// The list's deletes: one tunnel from a row's swipe, or the rows a delete
/// selection marks. Mac 2.2.1's `TunnelBulkDelete` is the source. Each
/// target is checked when its turn comes (`isSettledInactive`): a tunnel
/// with a session, or one on its way up, is reported as connected and left
/// alone, and a refused removal is reported with its error while the run
/// goes on. Mac gives up after three unreachable vault answers in a row;
/// iOS has no vault.
@MainActor
enum TunnelBulkDelete {

    enum Skip: Equatable {
        case connected
        case failed(String)
    }

    struct Skipped: Equatable {
        let name: String
        let skip: Skip
    }

    struct Report: Equatable {
        let deleted: [String]
        let skipped: [Skipped]

        /// @witness TunnelBulkDelete.aMixedSelectionDeletesOnlyTheSettledRows
        var total: Int { deleted.count + skipped.count }
    }

    /// The marked rows in list order; a mark for a row the list no longer
    /// holds is dropped.
    ///
    /// @witness TunnelBulkDelete.aMixedSelectionDeletesOnlyTheSettledRows
    static func targets(_ ordered: [TunnelContainer], marked: Set<UUID>) -> [TunnelContainer] {
        ordered.filter { marked.contains($0.id) }
    }

    /// Whether every row the gate lets go is marked; false while the gate
    /// lets none go.
    ///
    /// @witness TunnelBulkDelete.selectAllMarksTheRowsTheGateLetsGo
    static func allMarked(_ marked: Set<UUID>, rows: [TunnelContainer]) -> Bool {
        let eligible = Set(rows.filter(\.isSettledInactive).map(\.id))
        return !eligible.isEmpty && eligible.isSubset(of: marked)
    }

    /// The marks after Select All, which marks every row the gate lets go,
    /// or after Deselect All once all of them are marked, which takes those
    /// marks off. Mac 2.2.1's delete footer is the source.
    ///
    /// @witness TunnelBulkDelete.selectAllMarksTheRowsTheGateLetsGo
    static func toggledAll(_ marked: Set<UUID>, rows: [TunnelContainer]) -> Set<UUID> {
        let eligible = Set(rows.filter(\.isSettledInactive).map(\.id))
        return allMarked(marked, rows: rows) ? marked.subtracting(eligible) : marked.union(eligible)
    }

    /// Removes each target in turn and counts every target on `onProgress`,
    /// the skipped and the refused ones included.
    ///
    /// @witness TunnelBulkDelete.aMixedSelectionDeletesOnlyTheSettledRows
    /// @witness TunnelBulkDelete.aSettledSelectionDeletesWhole
    static func run(
        _ targets: [TunnelContainer],
        in manager: TunnelsManager,
        onProgress: (Int) -> Void = { _ in }
    ) async -> Report {
        var deleted: [String] = []
        var skipped: [Skipped] = []
        for (index, tunnel) in targets.enumerated() {
            defer { onProgress(index + 1) }
            guard tunnel.isSettledInactive else {
                skipped.append(Skipped(name: tunnel.name, skip: .connected))
                continue
            }
            do {
                try await manager.remove(tunnel: tunnel)
                deleted.append(tunnel.name)
            } catch {
                skipped.append(Skipped(name: tunnel.name, skip: .failed(error.localizedDescription)))
            }
        }
        return Report(deleted: deleted, skipped: skipped)
    }

    /// @witness TunnelBulkDelete.aSettledSelectionDeletesWhole
    static func confirmMessage(_ names: [String], loc: LocalizationManager) -> String {
        let shown = TunnelBulkExport.shownLines
        var lines = [loc.t("tunnel_list_delete_confirm_message")]
        lines += names.prefix(shown).map { "• \($0)" }
        if names.count > shown {
            lines.append(loc.t("import_report_more", names.count - shown))
        }
        return lines.joined(separator: "\n")
    }

    /// @witness TunnelBulkDelete.aMixedSelectionDeletesOnlyTheSettledRows
    static func title(_ report: Report, loc: LocalizationManager) -> String {
        report.deleted.isEmpty
            ? loc.t("delete_report_none")
            : loc.t("delete_report_partial", report.deleted.count, report.total)
    }

    /// @witness TunnelBulkDelete.aMixedSelectionDeletesOnlyTheSettledRows
    static func message(_ report: Report, loc: LocalizationManager) -> String {
        let shown = TunnelBulkExport.shownLines
        var lines = report.skipped.prefix(shown).map { "\($0.name) — \(reason($0.skip, loc: loc))" }
        if report.skipped.count > shown {
            lines.append(loc.t("import_report_more", report.skipped.count - shown))
        }
        return lines.joined(separator: "\n")
    }

    /// @witness TunnelBulkDelete.aMixedSelectionDeletesOnlyTheSettledRows
    static func reason(_ skip: Skip, loc: LocalizationManager) -> String {
        switch skip {
        case .connected:
            return loc.t("delete_skip_connected")
        case .failed(let message):
            return message
        }
    }
}
