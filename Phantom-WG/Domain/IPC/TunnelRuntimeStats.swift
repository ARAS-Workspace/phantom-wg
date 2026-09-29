import Foundation

/// The three runtime numbers the detail screen shows, and nothing else.
///
/// WireGuard reports them inside its UAPI `get` dump, which in the same
/// breath carries the interface's `private_key` and every peer's
/// `preshared_key`. Handing that dump to the app so it can pick three
/// integers out of it would move the tunnel's secrets through an IPC
/// reply once a second, for the app to read past and discard — so the
/// picking happens on the side that already holds them, and only the
/// numbers cross.
///
/// Spoken by both sides of opcode `0` as JSON, the same way the log
/// buffer already travels. The extension ships inside the app, so the
/// two ends are always the same build: the wire is versioned by living
/// together, and an older reply shape cannot arrive.
struct TunnelRuntimeStats: Codable, Sendable, Equatable {
    var rxBytes: Int64 = 0
    var txBytes: Int64 = 0
    var lastHandshakeTimestamp: Int64 = 0

    /// Reads the three numbers out of WireGuard's UAPI `get` output.
    /// Transfer counters are summed across peers; the handshake is the
    /// last one reported. Every other key in that output is stepped
    /// over without being copied anywhere.
    static func read(fromUAPI config: String) -> TunnelRuntimeStats {
        var stats = TunnelRuntimeStats()

        for line in config.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = parts[1]

            switch key {
            case "rx_bytes":
                stats.rxBytes += Int64(value) ?? 0
            case "tx_bytes":
                stats.txBytes += Int64(value) ?? 0
            case "last_handshake_time_sec":
                stats.lastHandshakeTimestamp = Int64(value) ?? 0
            default:
                break
            }
        }

        return stats
    }

    /// `nil` when there is no reply to read — the caller leaves the
    /// numbers it is already showing alone rather than painting zeros
    /// over them.
    static func decoded(from data: Data?) -> TunnelRuntimeStats? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(TunnelRuntimeStats.self, from: data)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
