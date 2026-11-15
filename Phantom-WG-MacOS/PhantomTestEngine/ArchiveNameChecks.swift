// ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
// ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
// ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
// ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
// ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
// ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
//
// Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
// Licensed under AGPL-3.0 - see LICENSE file for details
// WireGuard® is a registered trademark of Jason A. Donenfeld.
//
// Test Engine: Archive Name Checks
//
// The checks ArchiveNamesWorkflow runs, kept apart from the workflow so the
// same code compiles outside the app. Each archive is written byte by byte
// here, as Windows' built-in zip writes one: stored entries, no UTF-8 flag
// unless the case sets it, the name in the bytes given, each entry holding
// its own name.

#if DEBUG
import Foundation

enum ArchiveNameChecks {

    struct Outcome {
        let id: String
        let passed: Bool
        let message: String
    }

    struct FixtureEntry {
        let name: [UInt8]
        let host: UInt16
        var flag: UInt16 = 0
        var extra: [UInt8] = []
    }

    static let limits = ZipArchive.Limits(listed: 64, selected: 64, entryBytes: 64 * 1024)

    // MARK: - Windows code pages

    static func windowsCodePages(in directory: URL) -> [Outcome] {
        let cases: [(id: String, entry: FixtureEntry, expected: String)] = [
            ("A1", FixtureEntry(name: latin("\u{9E}irket Raporu.conf"), host: 0), "Şirket Raporu.conf"),
            ("A2", FixtureEntry(name: latin("A\u{A7}ustos \u{99}zetleri/\u{98}\u{87}erik \u{8D}\u{9F}\u{8D}k.conf"), host: 0),
             "Ağustos Özetleri/İçerik ışık.conf"),
            ("A3", FixtureEntry(name: latin("\u{DE}ube.conf"), host: 14), "Şube.conf"),
            ("A4", FixtureEntry(name: Array("Unix şarkı.conf".utf8), host: 3), "Unix şarkı.conf"),
            ("A5", FixtureEntry(name: latin("\u{9E}ehir NTFS.conf"), host: 11), "Şehir NTFS.conf"),
            ("A8", FixtureEntry(name: latin("Dosya\u{81}.conf"), host: 14), "Dosya\u{FC}.conf"),
        ]
        let url = directory.appendingPathComponent("windows.zip")
        var outcomes: [Outcome] = []
        do {
            try windowsZip(cases.map(\.entry)).write(to: url)
            let turkish = try ZipArchive.entries(at: url, limits: limits, pages: .turkey) { _ in true }
            for (index, item) in cases.enumerated() {
                let entry = turkish.indices.contains(index) ? turkish[index] : nil
                outcomes.append(Outcome(
                    id: item.id,
                    passed: entry?.path == item.expected && entry?.content == .success(Data(item.entry.name)),
                    message: "host \(item.entry.host) name reads as \(item.expected): \(entry?.path ?? "missing")"
                ))
            }
            let american = try ZipArchive.entries(at: url, limits: limits, pages: .unitedStates) { _ in true }
            outcomes.append(Outcome(
                id: "A6",
                passed: american.first?.path == "\u{20A7}irket Raporu.conf",
                message: "outside Turkey the same OEM name reads in CP437: \(american.first?.path ?? "missing")"
            ))
        } catch {
            outcomes.append(Outcome(id: "A0", passed: false, message: "windows.zip did not read: \(error)"))
        }
        outcomes.append(Outcome(
            id: "A7",
            passed: WindowsCodePages(region: "TR") == .turkey
                && WindowsCodePages(region: "US") == .unitedStates
                && WindowsCodePages(region: nil) == .unitedStates,
            message: "the TR region picks 857/1254, any other region 437/1252"
        ))
        return outcomes
    }

    // MARK: - Unicode path field and UTF-8 flag

    static func unicodePathField(in directory: URL) -> [Outcome] {
        let raw = latin("Ev A\u{A7}\u{8D}.conf")
        let crc = checksum(raw)
        let flagged = Array("Bayrak.conf".utf8)
        let cases: [(id: String, entry: FixtureEntry, expected: String)] = [
            ("B1", FixtureEntry(name: raw, host: 0, extra: unicodePath("Ev Ağı (Unicode).conf", crc: crc)),
             "Ev Ağı (Unicode).conf"),
            ("B2", FixtureEntry(name: raw, host: 0, extra: unicodePath("Ev Ağı (Unicode).conf", crc: crc &+ 1)),
             "Ev Ağı.conf"),
            ("B3", FixtureEntry(name: flagged, host: 0, flag: 0x0800, extra: unicodePath("Alan.conf", crc: checksum(flagged))),
             "Bayrak.conf"),
            ("B4", FixtureEntry(name: latin("\u{9E}ube.conf"), host: 0, flag: 0x0800), "Şube.conf"),
        ]
        let url = directory.appendingPathComponent("unicode-path.zip")
        do {
            try windowsZip(cases.map(\.entry)).write(to: url)
            let entries = try ZipArchive.entries(at: url, limits: limits, pages: .turkey) { _ in true }
            return cases.enumerated().map { index, item in
                let path = entries.indices.contains(index) ? entries[index].path : "missing"
                return Outcome(id: item.id, passed: path == item.expected, message: "reads as \(item.expected): \(path)")
            }
        } catch {
            return [Outcome(id: "B0", passed: false, message: "unicode-path.zip did not read: \(error)")]
        }
    }

    // MARK: - Own archive

    static func ownArchiveRoundTrip(in directory: URL) -> [Outcome] {
        let files: [(path: String, data: Data)] = [
            ("Ev Ağı.conf", Data("[Interface]\nPrivateKey = A\n".utf8)),
            ("Şirket İç Ağ.conf", Data("[Interface]\nPrivateKey = B\n".utf8)),
            ("Home.conf", Data("[Interface]\nPrivateKey = C\n".utf8)),
        ]
        let url = directory.appendingPathComponent("own.zip")
        do {
            try ZipArchive.write(files, to: url)
            let entries = try ZipArchive.entries(at: url, limits: limits, pages: .unitedStates) { _ in true }
            let headers = centralHeaders(of: try Data(contentsOf: url))
            return [
                Outcome(
                    id: "C1",
                    passed: entries.map(\.path) == files.map(\.path) && entries.map(\.content) == files.map { .success($0.data) },
                    message: "names and contents come back as written: \(entries.map(\.path))"
                ),
                Outcome(
                    id: "C2",
                    passed: headers.count == files.count && headers.allSatisfy { $0.flag & 0x0800 != 0 },
                    message: "every central header carries the UTF-8 flag: \(headers.map { String($0.flag, radix: 16) })"
                ),
                Outcome(
                    id: "C3",
                    passed: headers.count == files.count && headers.allSatisfy { $0.madeBy >> 8 == 3 && $0.attributes >> 16 == 0o100600 },
                    message: "every entry is made by Unix with mode 0600: \(headers.map { "\($0.madeBy >> 8)/\(String($0.attributes >> 16, radix: 8))" })"
                ),
            ]
        } catch {
            return [Outcome(id: "C0", passed: false, message: "own.zip did not round-trip: \(error)")]
        }
    }

    // MARK: - Fixtures

    static func latin(_ text: String) -> [UInt8] {
        text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        UInt32(truncatingIfNeeded: crc32(0, bytes, uInt(bytes.count)))
    }

    static func unicodePath(_ name: String, crc: UInt32) -> [UInt8] {
        let utf8 = Array(name.utf8)
        var field: [UInt8] = []
        put16(&field, 0x7075)
        put16(&field, UInt16(5 + utf8.count))
        field.append(1)
        put32(&field, crc)
        return field + utf8
    }

    static func windowsZip(_ entries: [FixtureEntry]) -> Data {
        var local: [UInt8] = []
        var central: [UInt8] = []
        for entry in entries {
            let size = UInt32(entry.name.count)
            let crc = checksum(entry.name)
            let offset = UInt32(local.count)
            put32(&local, 0x0403_4B50)
            for value in [20, entry.flag, 0, 0x6000, 0x5B4D] { put16(&local, value) }
            for value in [crc, size, size] { put32(&local, value) }
            put16(&local, UInt16(entry.name.count))
            put16(&local, 0)
            local += entry.name + entry.name

            put32(&central, 0x0201_4B50)
            for value in [entry.host << 8 | 20, 20, entry.flag, 0, 0x6000, 0x5B4D] { put16(&central, value) }
            for value in [crc, size, size] { put32(&central, value) }
            for value in [UInt16(entry.name.count), UInt16(entry.extra.count), 0, 0, 0] { put16(&central, value) }
            put32(&central, 0x20)
            put32(&central, offset)
            central += entry.name + entry.extra
        }
        var archive = local + central
        put32(&archive, 0x0605_4B50)
        for value in [0, 0, UInt16(entries.count), UInt16(entries.count)] { put16(&archive, value) }
        put32(&archive, UInt32(central.count))
        put32(&archive, UInt32(local.count))
        put16(&archive, 0)
        return Data(archive)
    }

    struct CentralHeader {
        let madeBy: UInt16
        let flag: UInt16
        let attributes: UInt32
    }

    static func centralHeaders(of data: Data) -> [CentralHeader] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22,
              let end = stride(from: bytes.count - 22, through: 0, by: -1).first(where: { read32(bytes, $0) == 0x0605_4B50 })
        else { return [] }
        let count = Int(read16(bytes, end + 10))
        var offset = Int(read32(bytes, end + 16))
        var headers: [CentralHeader] = []
        for _ in 0 ..< count {
            guard offset + 46 <= bytes.count, read32(bytes, offset) == 0x0201_4B50 else { return headers }
            headers.append(CentralHeader(
                madeBy: read16(bytes, offset + 4),
                flag: read16(bytes, offset + 8),
                attributes: read32(bytes, offset + 38)
            ))
            offset += 46 + Int(read16(bytes, offset + 28)) + Int(read16(bytes, offset + 30)) + Int(read16(bytes, offset + 32))
        }
        return headers
    }

    private static func put16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes += [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private static func put32(_ bytes: inout [UInt8], _ value: UInt32) {
        put16(&bytes, UInt16(value & 0xFFFF))
        put16(&bytes, UInt16(value >> 16))
    }

    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(read16(bytes, offset)) | UInt32(read16(bytes, offset + 2)) << 16
    }
}
#endif
