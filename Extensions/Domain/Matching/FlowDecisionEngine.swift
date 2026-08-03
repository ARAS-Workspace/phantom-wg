import Foundation

// MARK: - Flow Decision Engine

/// Flow decision helpers used by PhantomSplitTunnel's `handleNewFlow`.
/// The OS delivers every outbound TCP/UDP flow to our extension without
/// any signing-identifier filtering — the `NENetworkRule` we install
/// specifies only `protocol: .any, direction: .outbound`. Filtering is
/// runtime-only and happens here:
///
/// - `isOwnProcess` — self-bypass guard. Flows from our own processes
///   (main app, PhantomTunnel, PhantomSplitTunnel) are declined back
///   to the OS default route so the extension never loops its own
///   upstream traffic through itself.
/// - `matches` — user-app matching. Two-pass matrix (exact signing ID
///   + bundle-ID namespace) so a single entry captures both the main
///   process and its helper / service children.
///
/// Lives in Domain (not the provider) so the matching matrix stays
/// pure, side-effect-free logic that can be exercised without running
/// the proxy provider.
enum FlowDecisionEngine {

    /// Anything signed by our own team + bundle prefix must bypass
    /// back to the OS default route so the extension never loops its
    /// own upstream traffic through itself.
    ///
    /// Covers:
    /// - `com.remrearas.Phantom-WG-MacOS`              (main app)
    /// - `com.remrearas.Phantom-WG-MacOS.PhantomTunnel` (tunnel ext.)
    /// - `com.remrearas.Phantom-WG-MacOS.PhantomSplitTunnel`
    static let selfSigningPrefix = "9C5SL5H7CM.com.remrearas.Phantom-WG-MacOS"

    /// Returns `true` when the flow originates from one of our own
    /// processes. `handleNewFlow` translates that into `return false`
    /// (decline the flow) so the OS falls back to default routing.
    static func isOwnProcess(signingIdentifier: String?) -> Bool {
        guard let id = signingIdentifier, !id.isEmpty else { return false }
        return id.hasPrefix(selfSigningPrefix)
    }

    /// Two-pass match: first against the exact signing identifier (with
    /// team prefix when applicable), then against the bundle-ID
    /// namespace. The namespace pass catches helper processes and
    /// services signed with different team identifiers — e.g. a
    /// Chromium-based browser's main app might be `TEAM.com.vendor.Browser`
    /// while its network service is `com.vendor.Browser.helper` (or
    /// signed with a different team prefix). Adding the main app once
    /// routes all children of that bundle-ID namespace through bypass.
    static func matches(signingID: String, against app: AppEntry) -> Bool {
        // Exact signing identifier, plus subordinate-namespace prefix
        // (e.g. entry "TEAM.com.vendor.Browser" matches flow
        // "TEAM.com.vendor.Browser.helper").
        if signingID == app.signingIdentifier
            || signingID.hasPrefix(app.signingIdentifier + ".") {
            return true
        }

        // Bundle-ID namespace — covers helpers signed with a different
        // team prefix, or no prefix at all. The only thing that ever
        // legitimately precedes a bundle ID in a signing identifier is
        // a single 10-char Apple team ID, so strip at most that and
        // then anchor at the FRONT:
        //   "com.vendor.Browser"                 → core, exact
        //   "com.vendor.Browser.helper"          → core, subtree
        //   "ZZ99YY88XX.com.vendor.Browser.gpu"  → strip team, subtree
        //
        // Anchoring is the security boundary. The earlier hasSuffix /
        // contains passes matched the bundle ID anywhere in the string,
        // so an attacker-controlled app signed
        // "EVILTEAM00.evil.com.vendor.Browser" satisfied `hasSuffix(
        // ".com.vendor.Browser")` and silently bypassed the tunnel.
        // Stripping only a real team prefix, then requiring the bundle
        // ID at position zero, rejects that while still matching a
        // legitimate helper under a different team.
        let bundleID = app.bundleIdentifier
        let core = Self.withoutTeamPrefix(signingID)
        if core == bundleID || core.hasPrefix(bundleID + ".") {
            return true
        }

        return false
    }

    /// Drop a leading Apple team-identifier segment if present. Team
    /// IDs are exactly 10 characters, uppercase letters and digits
    /// (e.g. `9C5SL5H7CM`). Anything else — a longer segment, a
    /// lowercase reverse-DNS label — is left in place, so a spoofed
    /// prefix cannot be mistaken for a team and stripped away.
    static func withoutTeamPrefix(_ signingID: String) -> String {
        guard let dot = signingID.firstIndex(of: ".") else { return signingID }
        let head = signingID[..<dot]
        let isTeamID = head.count == 10 && head.allSatisfy {
            $0.isNumber || ($0.isLetter && $0.isUppercase)
        }
        return isTeamID ? String(signingID[signingID.index(after: dot)...]) : signingID
    }
}
