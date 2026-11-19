import Foundation

struct WindowsCodePages: Equatable {
    let oem: UInt32
    let ansi: UInt32

    static let unitedStates = WindowsCodePages(oem: 437, ansi: 1252)
    static let turkey = WindowsCodePages(oem: 857, ansi: 1254)

    static var current: WindowsCodePages {
        WindowsCodePages(region: Locale.current.region?.identifier)
    }

    init(oem: UInt32, ansi: UInt32) {
        self.oem = oem
        self.ansi = ansi
    }

    /// @witness ArchiveNames.windowsCodePages
    init(region: String?) {
        self = region == "TR" ? .turkey : .unitedStates
    }
}

enum ZipEntryName {

    static let utf8Flag: UInt = 0x0800

    private static let unicodePathTag: UInt16 = 0x7075
    private static let oemHosts: Set<UInt> = [0, 3, 11]
    private static let fallbackCodePage: UInt32 = 437

    /// @witness ArchiveNames.windowsCodePages
    /// @witness ArchiveNames.unicodePathField
    static func decode(_ raw: Data, flag: UInt, versionMadeBy: UInt, extra: Data, pages: WindowsCodePages) -> String {
        if flag & utf8Flag != 0, let flagged = String(bytes: raw, encoding: .utf8) {
            return flagged
        }
        if let unicode = unicodePath(in: extra, for: raw) {
            return unicode
        }
        if let utf8 = String(bytes: raw, encoding: .utf8) {
            return utf8
        }
        let page = oemHosts.contains(versionMadeBy >> 8) ? pages.oem : pages.ansi
        return decode(raw, codePage: page) ?? decode(raw, codePage: fallbackCodePage) ?? ""
    }

    private static func unicodePath(in extra: Data, for raw: Data) -> String? {
        let bytes = [UInt8](extra)
        var offset = 0
        while offset + 4 <= bytes.count {
            let tag = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            let size = Int(bytes[offset + 2]) | Int(bytes[offset + 3]) << 8
            let body = offset + 4
            guard body + size <= bytes.count else { return nil }
            if tag == unicodePathTag {
                return unicodePath(bytes[body ..< body + size], for: raw)
            }
            offset = body + size
        }
        return nil
    }

    private static func unicodePath(_ field: ArraySlice<UInt8>, for raw: Data) -> String? {
        let field = Array(field)
        guard field.count >= 5, field[0] <= 1 else { return nil }
        let stored = UInt(field[1]) | UInt(field[2]) << 8 | UInt(field[3]) << 16 | UInt(field[4]) << 24
        guard stored == checksum(raw) else { return nil }
        let name = field[5...]
        guard !name.contains(0) else { return nil }
        return String(bytes: name, encoding: .utf8)
    }

    private static func checksum(_ data: Data) -> UInt {
        data.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
        }
    }

    private static func decode(_ raw: Data, codePage: UInt32) -> String? {
        let encoding = CFStringConvertWindowsCodepageToEncoding(codePage)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String(bytes: raw, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)))
    }
}
