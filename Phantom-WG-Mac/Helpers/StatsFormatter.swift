import Foundation

enum StatsFormatter {

    struct RuntimeStats {
        var rxBytes: Int64 = 0
        var txBytes: Int64 = 0
        var lastHandshakeTimestamp: Int64 = 0
    }

    /// Parses WireGuard UAPI runtime configuration into structured stats.
    static func parse(_ config: String) -> RuntimeStats {
        var stats = RuntimeStats()

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

    /// Formats byte count into human-readable string (B, KB, MB, GB).
    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.2f MB", Double(bytes) / (1024 * 1024))
        } else {
            return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }

    /// Formats elapsed seconds into localized "time ago" string.
    static func formatTimeAgo(_ seconds: TimeInterval, loc: LocalizationManager) -> String {
        if seconds < 5 { return loc.t("time_just_now") }
        if seconds < 60 { return loc.t("time_seconds_ago", Int(seconds)) }
        if seconds < 3600 {
            let m = Int(seconds) / 60
            let s = Int(seconds) % 60
            return loc.t("time_minutes_seconds_ago", m, s)
        }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return loc.t("time_hours_minutes_ago", h, m)
    }
}
