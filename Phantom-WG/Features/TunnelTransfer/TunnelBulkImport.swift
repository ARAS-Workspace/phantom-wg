import Foundation

/// The list's bulk import: every `.conf` among the picked files and inside
/// the picked zip archives is read, validated and added through `add()`;
/// what is not added is reported with its reason. Mac 2.2.1's
/// `TunnelBulkImport` is the source. Mac gives up after three unreachable
/// vault answers in a row; iOS has no vault, and how a refused VPN
/// permission answers a run of adds is to be measured on a device first.
@MainActor
enum TunnelBulkImport {

    struct Skipped {
        let label: String
        let skip: TunnelImportBatch.Skip
    }

    struct Report {
        var added: [String] = []
        var skipped: [Skipped] = []

        var total: Int { added.count + skipped.count }
    }

    /// @witness TunnelTransfer.filesAndAZipImportIntoOneList
    /// @witness TunnelTransfer.anExportedArchiveImportsBackTheSame
    static func run(
        _ urls: [URL],
        into manager: TunnelsManager,
        access: PickedFileAccess = .securityScoped
    ) async -> Report {
        let candidates = await Task.detached { TunnelImportBatch.candidates(from: urls, access: access) }.value
        var report = Report()
        for candidate in candidates {
            switch TunnelImportBatch.config(for: candidate) {
            case .failure(let skip):
                report.skipped.append(Skipped(label: candidate.label, skip: skip))
            case .success(let config):
                do {
                    _ = try await manager.add(config: config)
                    report.added.append(config.name)
                } catch {
                    report.skipped.append(Skipped(label: candidate.label, skip: .addFailed(error.localizedDescription)))
                }
            }
        }
        return report
    }

    static func title(_ report: Report, loc: LocalizationManager) -> String {
        report.added.isEmpty
            ? loc.t("import_report_none")
            : loc.t("import_report_partial", report.added.count, report.total)
    }

    static func message(_ report: Report, loc: LocalizationManager) -> String {
        let shown = TunnelBulkExport.shownLines
        var lines = report.skipped.prefix(shown).map { "\($0.label) — \(reason($0.skip, loc: loc))" }
        if report.skipped.count > shown {
            lines.append(loc.t("import_report_more", report.skipped.count - shown))
        }
        return lines.joined(separator: "\n")
    }

    static func reason(_ skip: TunnelImportBatch.Skip, loc: LocalizationManager) -> String {
        switch skip {
        case .unreadable:
            return loc.t("import_skip_unreadable")
        case .tooLarge:
            return loc.t("import_skip_too_large")
        case .encrypted:
            return loc.t("import_skip_encrypted")
        case .notText:
            return loc.t("import_skip_not_text")
        case .parse(let error):
            return ConfEditorMessages.parseMessage(error, loc: loc)
        case .fields(let errors):
            return ConfEditorMessages.fieldMessages(errors, loc: loc).joined(separator: ", ")
        case .archiveUnreadable:
            return loc.t("import_skip_archive_unreadable")
        case .archiveTooManyEntries:
            return loc.t("import_skip_archive_too_many")
        case .archiveEmpty:
            return loc.t("import_skip_archive_empty")
        case .addFailed(let message):
            return message
        }
    }
}
