import Foundation

enum TunnelResetReply: UInt8, Sendable {
    case rebuilt = 0

    case skipped = 1

    case wstunnelFailed = 2

    case adapterFailed = 3

    enum Reading: Sendable, Equatable {
        case absent
        case outcome(TunnelResetReply)
        case unrecognised(UInt8)
    }

    static func read(_ data: Data?) -> Reading {
        guard let data, data.count >= 2 else { return .absent }
        let raw = data[data.startIndex + 1]
        guard let reply = TunnelResetReply(rawValue: raw) else { return .unrecognised(raw) }
        return .outcome(reply)
    }
}
