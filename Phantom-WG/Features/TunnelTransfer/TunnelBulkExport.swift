import Foundation

/// The list's bulk export: once the owner grants it, every listed tunnel
/// whose configuration reads back goes into one zip archive, built in
/// memory. Mac 2.2.1's `TunnelBulkExport` is the source; there the
/// payloads came from the vault and the archive was written to the file
/// the save panel chose. Here they come from each tunnel's Keychain item,
/// and the archive goes to the export picker as an `ExportedFile`.
@MainActor
enum TunnelBulkExport {

    enum Outcome: Equatable {
        case archived(ExportedFile, count: Int, total: Int, unread: [String])
        case nothing(unread: [String])
        case unwritable
        case declined
    }

    static let shownLines = 20

    /// @witness TunnelTransfer.theBulkExportArchivesEveryReadableTunnel
    /// @witness TunnelTransfer.theBulkExportAsksTheOwnerFirst
    static func run(
        _ tunnels: [TunnelContainer],
        reason: String,
        authorize: (String) async -> PrivateDataAuthorization.Outcome = PrivateDataAuthorization.request,
        onFailure: (String) -> Void
    ) async -> Outcome {
        guard await PrivateDataGuard.grants(reason: reason, authorize: authorize, onFailure: onFailure) else {
            return .declined
        }
        let plan = TunnelExportBatch.plan(
            listed: tunnels.map { TunnelExportBatch.Listed(id: $0.id, name: $0.name) },
            payloads: tunnels.compactMap(\.tunnelConfig)
        )
        guard !plan.files.isEmpty else { return .nothing(unread: plan.unread) }
        guard let data = try? ZipArchive.archive(plan.files) else { return .unwritable }
        return .archived(
            ExportedFile(data: data, name: TunnelExportBatch.defaultFileName),
            count: plan.files.count,
            total: tunnels.count,
            unread: plan.unread
        )
    }

    static func unreadLines(_ names: [String], loc: LocalizationManager) -> String {
        var lines = names.prefix(shownLines).map { "\($0) — \(loc.t("export_skip_unread"))" }
        if names.count > shownLines {
            lines.append(loc.t("import_report_more", names.count - shownLines))
        }
        return lines.joined(separator: "\n")
    }
}
