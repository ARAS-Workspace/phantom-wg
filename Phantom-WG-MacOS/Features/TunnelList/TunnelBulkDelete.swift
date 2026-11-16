import Foundation

@MainActor
enum TunnelBulkDelete {

    static let shownLines = 20

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

        var total: Int { deleted.count + skipped.count }
    }

    static func targets(_ ordered: [TunnelContainer], marked: Set<UUID>) -> [TunnelContainer] {
        ordered.filter { marked.contains($0.id) }
    }

    static func run(_ targets: [TunnelContainer], in manager: TunnelsManager) async -> Report {
        var deleted: [String] = []
        var skipped = targets.filter { !$0.isSettledInactive }.map { Skipped(name: $0.name, skip: .connected) }
        for tunnel in targets where tunnel.isSettledInactive {
            manager.startDeactivation(of: tunnel)
            do {
                try await manager.remove(tunnel: tunnel)
                deleted.append(tunnel.name)
            } catch {
                skipped.append(Skipped(name: tunnel.name, skip: .failed(error.localizedDescription)))
            }
        }
        return Report(deleted: deleted, skipped: skipped)
    }

    static func confirmMessage(_ names: [String], loc: LocalizationManager) -> String {
        var lines = [loc.t("tunnel_list_delete_confirm_message")]
        lines += names.prefix(shownLines).map { "• \($0)" }
        if names.count > shownLines {
            lines.append(loc.t("import_report_more", names.count - shownLines))
        }
        return lines.joined(separator: "\n")
    }

    static func title(_ report: Report, loc: LocalizationManager) -> String {
        report.deleted.isEmpty
            ? loc.t("delete_report_none")
            : loc.t("delete_report_partial", report.deleted.count, report.total)
    }

    static func message(_ report: Report, loc: LocalizationManager) -> String {
        var lines = report.skipped.prefix(shownLines).map { "\($0.name) — \(reason($0.skip, loc: loc))" }
        if report.skipped.count > shownLines {
            lines.append(loc.t("import_report_more", report.skipped.count - shownLines))
        }
        return lines.joined(separator: "\n")
    }

    static func reason(_ skip: Skip, loc: LocalizationManager) -> String {
        switch skip {
        case .connected:
            return loc.t("delete_skip_connected")
        case .failed(let message):
            return message
        }
    }
}
