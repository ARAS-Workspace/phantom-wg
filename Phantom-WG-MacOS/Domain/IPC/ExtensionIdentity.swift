import Foundation

/// The app ↔ extension contract stamp, compiled from this one source
/// file into all four targets. A daemon answers its identity probe
/// with this value computed inside the extension process; the
/// extension gate compares it against the same value computed inside
/// the app process. Equality means the installed extension was built
/// from the same release the app ships, so activation — a full
/// replacement that kills the extension's running sessions — can be
/// skipped.
///
/// The stamp is MARKETING_VERSION, nothing bespoke: `bump.sh` moves
/// it on every release, so updates always mismatch without any extra
/// discipline. CURRENT_PROJECT_VERSION is deliberately not part of
/// the stamp. Dev builds under an unchanged marketing version keep
/// the installed extension — force a replacement with a temporary
/// version bump or the app's uninstall flow; the skipped-activation
/// log line is the tell when a rebuild kept the old extension.
public enum ExtensionIdentity {

    /// The identity this process reports and expects. All targets
    /// share one MARKETING_VERSION by construction, so the app's own
    /// value doubles as the expected value for every embedded
    /// extension.
    public static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
