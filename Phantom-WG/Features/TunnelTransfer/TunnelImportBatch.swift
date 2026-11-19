import Foundation

/// How a picked file is opened: the system hands the file importer's URLs
/// out under security-scoped access, which is asked for before a file is
/// read and released after it.
struct PickedFileAccess: Sendable {
    let start: @Sendable (URL) -> Bool
    let stop: @Sendable (URL) -> Void

    static let securityScoped = PickedFileAccess(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// The bulk import's reading of picked files. Mac 2.2.1's `TunnelImportBatch`
/// is the source. On iOS each picked file is read inside its access
/// (`PickedFileAccess`), and whether it is a zip archive is read from its
/// first bytes, not its name: the app declares no type for `.conf`, and a
/// file that is not an archive is read as a `.conf` and decided by
/// `ConfParser` and `validate()`. Inside an archive, Mac's rule holds:
/// entries named `.conf` are read and AppleDouble entries are passed over.
enum TunnelImportBatch {

    static let limits = ZipArchive.Limits(listed: 5000, selected: 500, entryBytes: 64 * 1024)

    /// A local file header, and the end record of an archive with no entry.
    private static let zipSignatures: [[UInt8]] = [[0x50, 0x4B, 0x03, 0x04], [0x50, 0x4B, 0x05, 0x06]]

    enum Skip: Error, Equatable {
        case unreadable
        case tooLarge
        case encrypted
        case notText
        case parse(ConfParser.ParseError)
        case fields([TunnelDraft.Field: FieldValidationError])
        case archiveUnreadable
        case archiveTooManyEntries
        case archiveEmpty
        case addFailed(String)
    }

    struct Candidate: Equatable {
        let label: String
        let name: String
        let content: Result<Data, Skip>
    }

    /// @witness TunnelTransfer.filesAndAZipImportIntoOneList
    /// @witness TunnelTransfer.theContentDecidesNotTheName
    /// @witness TunnelTransfer.everyPickedFilesAccessIsReleased
    static func candidates(
        from urls: [URL],
        pages: WindowsCodePages = .current,
        access: PickedFileAccess = .securityScoped
    ) -> [Candidate] {
        urls
            .flatMap { url -> [Candidate] in
                let granted = access.start(url)
                defer { if granted { access.stop(url) } }
                return isZipArchive(url) ? archiveCandidates(url, pages: pages) : [fileCandidate(url)]
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    static func config(for candidate: Candidate) -> Result<TunnelConfig, Skip> {
        let data: Data
        switch candidate.content {
        case .failure(let skip):
            return .failure(skip)
        case .success(let bytes):
            data = bytes
        }
        guard let text = String(bytes: data, encoding: .utf8) else { return .failure(.notText) }

        var draft: TunnelDraft
        do {
            draft = try ConfParser.parse(text)
        } catch let error as ConfParser.ParseError {
            return .failure(.parse(error))
        } catch {
            return .failure(.unreadable)
        }
        draft.name = candidate.name

        let result = draft.validate()
        guard let config = result.config else { return .failure(.fields(result.errors)) }
        return .success(config)
    }

    /// The tunnel name a file or an archive entry is added under: its last
    /// path component with a trailing `.conf` taken off, as on Mac. Nothing
    /// else is read into the name, so a file the Files app named
    /// `X.conf 2` (Keep Both) is added as `X.conf 2`.
    ///
    /// @witness TunnelTransfer.filesAndAZipImportIntoOneList
    /// @witness TunnelTransfer.theContentDecidesNotTheName
    static func tunnelName(fromPath path: String) -> String {
        let last = (path as NSString).lastPathComponent
        let base = last.lowercased().hasSuffix(".conf") ? String(last.dropLast(5)) : last
        return base.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    static func isConfPath(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".conf")
    }

    static func isAppleDouble(_ path: String) -> Bool {
        path.hasPrefix("__MACOSX/") || (path as NSString).lastPathComponent.hasPrefix("._")
    }

    /// @witness TunnelTransfer.theContentDecidesNotTheName
    static func isZipArchive(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4) else { return false }
        return zipSignatures.contains([UInt8](head))
    }

    private static func fileCandidate(_ url: URL) -> Candidate {
        let label = url.lastPathComponent
        let name = tunnelName(fromPath: label)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return Candidate(label: label, name: name, content: .failure(.unreadable))
        }
        guard size <= limits.entryBytes else {
            return Candidate(label: label, name: name, content: .failure(.tooLarge))
        }
        guard let data = try? Data(contentsOf: url) else {
            return Candidate(label: label, name: name, content: .failure(.unreadable))
        }
        return Candidate(label: label, name: name, content: .success(data))
    }

    private static func archiveCandidates(_ url: URL, pages: WindowsCodePages) -> [Candidate] {
        let archive = url.lastPathComponent
        let entries: [ZipArchive.Entry]
        do {
            entries = try ZipArchive.entries(at: url, limits: limits, pages: pages) { path in
                isConfPath(path) && !isAppleDouble(path)
            }
        } catch ZipArchive.Failure.tooManyEntries {
            return [Candidate(label: archive, name: "", content: .failure(.archiveTooManyEntries))]
        } catch {
            return [Candidate(label: archive, name: "", content: .failure(.archiveUnreadable))]
        }
        guard !entries.isEmpty else {
            return [Candidate(label: archive, name: "", content: .failure(.archiveEmpty))]
        }
        return entries.map { entry in
            Candidate(
                label: "\(archive) › \(entry.path)",
                name: tunnelName(fromPath: entry.path),
                content: entry.content.mapError(skip)
            )
        }
    }

    private static func skip(_ problem: ZipArchive.EntryProblem) -> Skip {
        switch problem {
        case .encrypted:
            return .encrypted
        case .tooLarge:
            return .tooLarge
        case .unreadable:
            return .unreadable
        }
    }
}
