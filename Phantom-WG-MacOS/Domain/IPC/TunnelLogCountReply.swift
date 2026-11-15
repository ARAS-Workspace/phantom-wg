import Foundation

enum TunnelLogCountReply {

    static let opcode: UInt8 = 4

    static func encode(_ count: Int) -> Data {
        let value = UInt32(clamping: count)
        return Data([
            opcode,
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ])
    }

    static func read(_ data: Data?) -> Int? {
        guard let data, data.count == 5, data[data.startIndex] == opcode else { return nil }
        return data.dropFirst().reduce(0) { $0 << 8 | Int($1) }
    }
}
