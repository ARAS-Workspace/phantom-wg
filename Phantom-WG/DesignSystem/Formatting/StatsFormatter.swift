import Foundation

/// Presentation only — the numbers themselves arrive already read, in
/// `TunnelRuntimeStats`. This stays on the app side because
/// `formatTimeAgo` speaks to the localization catalogue, and the
/// extension has no localization layer.
enum StatsFormatter {

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
