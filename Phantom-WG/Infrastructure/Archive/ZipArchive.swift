import Foundation

/// Zip archives through MiniZip. An archive is read from a file
/// (`entries(at:)`) or from bytes already in memory (`entries(in:)`); the
/// app's own archive is built in memory and handed back as bytes
/// (`archive(_:)`), and MiniZip opens no file to write it. The bytes reach
/// a file only when `TunnelExportPicker` stages them for the export picker.
/// Entry contents are read into memory, never extracted to disk. Mac 2.2.1's
/// reader is kept as it is; its writer wrote to a file the save panel named.
enum ZipArchive {

    struct Limits: Equatable {
        let listed: Int
        let selected: Int
        let entryBytes: Int
    }

    enum Failure: Error, Equatable {
        case unreadable
        case tooManyEntries
        case unwritable
        case nameTooLong(String)
    }

    enum EntryProblem: Error, Equatable {
        case encrypted
        case tooLarge
        case unreadable
    }

    struct Entry: Equatable {
        let path: String
        let content: Result<Data, EntryProblem>
    }

    private static let encryptedFlag: UInt = 0x0001
    private static let madeByUnix: UInt = 3 << 8 | 20
    private static let ownerReadWriteFile: UInt = 0o100600 << 16
    private static let maximumNameBytes = 0xFFFF

    /// @witness ArchiveNames.windowsCodePages
    /// @witness ArchiveNames.unicodePathField
    /// @witness ArchiveNames.ownArchiveRoundTrip
    static func entries(
        at url: URL,
        limits: Limits,
        pages: WindowsCodePages = .current,
        where select: (String) -> Bool
    ) throws -> [Entry] {
        guard let archive = url.path.withCString({ unzOpen64($0) }) else {
            throw Failure.unreadable
        }
        defer { unzClose(archive) }
        return try entries(of: archive, limits: limits, pages: pages, where: select)
    }

    /// @witness ArchiveNames.ownArchiveRoundTrip
    static func entries(
        in data: Data,
        limits: Limits,
        pages: WindowsCodePages = .current,
        where select: (String) -> Bool
    ) throws -> [Entry] {
        let stream = ZipMemoryStream(data)
        return try withExtendedLifetime(stream) {
            var functions = stream.functions
            guard let archive = unzOpen2_64(nil, &functions) else {
                throw Failure.unreadable
            }
            defer { unzClose(archive) }
            return try entries(of: archive, limits: limits, pages: pages, where: select)
        }
    }

    private static func entries(
        of archive: unzFile,
        limits: Limits,
        pages: WindowsCodePages,
        where select: (String) -> Bool
    ) throws -> [Entry] {
        var global = unz_global_info64()
        guard unzGetGlobalInfo64(archive, &global) == UNZ_OK else { throw Failure.unreadable }
        guard global.number_entry <= UInt64(limits.listed) else { throw Failure.tooManyEntries }

        var entries: [Entry] = []
        var name = [CChar](repeating: 0, count: maximumNameBytes + 1)
        var extra = [UInt8](repeating: 0, count: maximumNameBytes + 1)
        var status = unzGoToFirstFile(archive)
        while status == UNZ_OK {
            var info = unz_file_info64()
            guard unzGetCurrentFileInfo64(archive, &info, &name, UInt(name.count), &extra, UInt(extra.count), nil, 0) == UNZ_OK else {
                throw Failure.unreadable
            }
            let path = ZipEntryName.decode(
                Data(name.prefix(Int(info.size_filename)).map { UInt8(bitPattern: $0) }),
                flag: info.flag,
                versionMadeBy: info.version,
                extra: Data(extra.prefix(Int(info.size_file_extra))),
                pages: pages
            )
            if !path.hasSuffix("/"), select(path) {
                guard entries.count < limits.selected else { throw Failure.tooManyEntries }
                entries.append(Entry(path: path, content: content(of: archive, info: info, limit: limits.entryBytes)))
            }
            status = unzGoToNextFile(archive)
        }
        guard status == UNZ_END_OF_LIST_OF_FILE else { throw Failure.unreadable }
        return entries
    }

    private static func content(of archive: unzFile, info: unz_file_info64, limit: Int) -> Result<Data, EntryProblem> {
        if info.flag & encryptedFlag != 0 { return .failure(.encrypted) }
        guard info.uncompressed_size <= UInt64(limit) else { return .failure(.tooLarge) }
        guard unzOpenCurrentFile(archive) == UNZ_OK else { return .failure(.unreadable) }

        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var data = Data()
        var read: Int32
        repeat {
            read = unzReadCurrentFile(archive, &buffer, UInt32(buffer.count))
            if read > 0 { data.append(buffer, count: Int(read)) }
        } while read > 0
        let closed = unzCloseCurrentFile(archive)
        guard read == 0, closed == UNZ_OK else { return .failure(.unreadable) }
        return .success(data)
    }

    /// @witness ArchiveNames.ownArchiveRoundTrip
    static func archive(_ files: [(path: String, data: Data)], date: Date = Date()) throws -> Data {
        if let long = files.first(where: { $0.path.utf8.count > maximumNameBytes }) {
            throw Failure.nameTooLong(long.path)
        }
        let stream = ZipMemoryStream()
        return try withExtendedLifetime(stream) {
            var functions = stream.functions
            guard let archive = zipOpen2_64(nil, APPEND_STATUS_CREATE, nil, &functions) else {
                throw Failure.unwritable
            }
            let added = add(files, to: archive, date: date)
            let closed = zipClose(archive, nil) == ZIP_OK
            guard added, closed, !stream.failed else { throw Failure.unwritable }
            return stream.data
        }
    }

    private static func add(_ files: [(path: String, data: Data)], to archive: zipFile, date: Date) -> Bool {
        var info = zip_fileinfo(tmz_date: dosDate(date), dosDate: 0, internal_fa: 0, external_fa: ownerReadWriteFile)
        for file in files {
            let opened = file.path.withCString { name in
                zipOpenNewFileInZip4_64(
                    archive, name, &info, nil, 0, nil, 0, nil,
                    Z_DEFLATED, Z_DEFAULT_COMPRESSION, 0, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                    nil, 0, madeByUnix, ZipEntryName.utf8Flag, 0
                )
            }
            guard opened == ZIP_OK else { return false }
            let written = file.data.withUnsafeBytes { bytes in
                zipWriteInFileInZip(archive, bytes.baseAddress, UInt32(bytes.count))
            }
            let closed = zipCloseFileInZip(archive)
            guard written == ZIP_OK, closed == ZIP_OK else { return false }
        }
        return true
    }

    private static func dosDate(_ date: Date) -> tm_zip {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return tm_zip(
            tm_sec: uInt(parts.second ?? 0),
            tm_min: uInt(parts.minute ?? 0),
            tm_hour: uInt(parts.hour ?? 0),
            tm_mday: uInt(parts.day ?? 1),
            tm_mon: uInt((parts.month ?? 1) - 1),
            tm_year: uInt(parts.year ?? 1980)
        )
    }
}
