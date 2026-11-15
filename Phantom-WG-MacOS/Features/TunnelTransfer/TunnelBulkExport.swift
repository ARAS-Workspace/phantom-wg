import Foundation

@MainActor
enum TunnelBulkExport {

    enum Outcome {
        case exported(count: Int, total: Int, unread: [String])
        case nothing(unread: [String])
        case vaultUnavailable
        case unwritable
    }

    static func run(_ tunnels: [TunnelContainer], vault: TunnelVaultClient, to url: URL) async -> Outcome {
        guard case .configs(let payloads) = await vault.readAll() else { return .vaultUnavailable }
        let plan = TunnelExportBatch.plan(
            listed: tunnels.map { TunnelExportBatch.Listed(id: $0.id, name: $0.name) },
            payloads: payloads
        )
        guard !plan.files.isEmpty else { return .nothing(unread: plan.unread) }

        let files = plan.files
        let written = await Task.detached { (try? ZipArchive.write(files, to: url)) != nil }.value
        guard written else { return .unwritable }
        return .exported(count: files.count, total: tunnels.count, unread: plan.unread)
    }

    static func unreadLines(_ names: [String], loc: LocalizationManager) -> String {
        var lines = names.prefix(TunnelBulkImport.shownLines).map { "\($0) — \(loc.t("export_skip_unread"))" }
        if names.count > TunnelBulkImport.shownLines {
            lines.append(loc.t("import_report_more", names.count - TunnelBulkImport.shownLines))
        }
        return lines.joined(separator: "\n")
    }
}
