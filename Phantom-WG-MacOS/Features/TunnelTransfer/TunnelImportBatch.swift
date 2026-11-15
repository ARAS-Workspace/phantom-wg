import Foundation

enum TunnelImportBatch {

    static let limits = ZipArchive.Limits(listed: 5000, selected: 500, entryBytes: 64 * 1024)

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

    static func candidates(from urls: [URL], pages: WindowsCodePages = .current) -> [Candidate] {
        urls
            .flatMap { url in
                url.pathExtension.lowercased() == "zip" ? archiveCandidates(url, pages: pages) : [fileCandidate(url)]
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
