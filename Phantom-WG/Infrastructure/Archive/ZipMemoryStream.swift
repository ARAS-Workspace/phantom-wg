import Foundation

/// The bytes MiniZip reads and writes through `functions` while it holds an
/// archive in memory: a buffer and a position, read, written and sought the
/// way MiniZip uses a file. A write past the end grows the buffer and a
/// write inside it overwrites in place, as MiniZip's rewrite of a local
/// header needs. A seek to a negative position, past `Int`'s range or from
/// an unknown origin answers -1 and marks the stream failed. MiniZip asks
/// the error call only when a header field comes up short;
/// `ZipArchive.archive(_:)` reads the mark once the archive is closed.
///
/// `functions` refers to the stream without retaining it: the stream must
/// outlive every archive handle opened over them.
final class ZipMemoryStream {
    private(set) var bytes: [UInt8]
    private(set) var failed = false
    private var position = 0

    init(_ data: Data = Data()) {
        bytes = [UInt8](data)
    }

    var data: Data { Data(bytes) }

    var functions: zlib_filefunc64_def {
        zlib_filefunc64_def(
            zopen64_file: { opaque, _, _ in opaque },
            zread_file: { opaque, _, buffer, size in ZipMemoryStream.of(opaque)?.read(into: buffer, size) ?? 0 },
            zwrite_file: { opaque, _, buffer, size in ZipMemoryStream.of(opaque)?.write(from: buffer, size) ?? 0 },
            ztell64_file: { opaque, _ in ZipMemoryStream.of(opaque).map { ZPOS64_T($0.position) } ?? 0 },
            zseek64_file: { opaque, _, offset, origin in ZipMemoryStream.of(opaque)?.seek(to: offset, from: origin) ?? -1 },
            zclose_file: { _, _ in 0 },
            zerror_file: { opaque, _ in ZipMemoryStream.of(opaque)?.failed == false ? 0 : 1 },
            opaque: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// MiniZip hands every call back the opaque value `functions` carries,
    /// which is this stream.
    private static func of(_ opaque: voidpf?) -> ZipMemoryStream? {
        opaque.map { Unmanaged<ZipMemoryStream>.fromOpaque($0).takeUnretainedValue() }
    }

    private func read(into buffer: UnsafeMutableRawPointer?, _ size: uLong) -> uLong {
        guard let buffer, position < bytes.count else { return 0 }
        let count = min(Int(size), bytes.count - position)
        bytes.withUnsafeBytes { source in
            if let base = source.baseAddress {
                buffer.copyMemory(from: base + position, byteCount: count)
            }
        }
        position += count
        return uLong(count)
    }

    private func write(from buffer: UnsafeRawPointer?, _ size: uLong) -> uLong {
        guard let buffer, size > 0 else { return 0 }
        let count = Int(size)
        let end = position + count
        if end > bytes.count {
            bytes.append(contentsOf: repeatElement(0, count: end - bytes.count))
        }
        bytes.withUnsafeMutableBytes { target in
            if let base = target.baseAddress {
                (base + position).copyMemory(from: buffer, byteCount: count)
            }
        }
        position = end
        return size
    }

    private func seek(to offset: ZPOS64_T, from origin: Int32) -> Int {
        let base: Int
        switch origin {
        case ZLIB_FILEFUNC_SEEK_SET:
            base = 0
        case ZLIB_FILEFUNC_SEEK_CUR:
            base = position
        case ZLIB_FILEFUNC_SEEK_END:
            base = bytes.count
        default:
            failed = true
            return -1
        }
        let (target, overflow) = base.addingReportingOverflow(Int(Int64(bitPattern: offset)))
        guard !overflow, target >= 0 else {
            failed = true
            return -1
        }
        position = target
        return 0
    }
}
