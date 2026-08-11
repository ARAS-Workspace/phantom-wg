import Foundation
import NetworkExtension

/// Verdict about the system's one exclusive VPN slot.
enum SlotVerdict: Equatable {
    case free
    /// Another local user's session occupies the slot. The name is the
    /// configuration's system-store label — world-readable and already
    /// shown to every user in System Settings > VPN, so surfacing it
    /// discloses nothing the OS does not. The owning ACCOUNT is never
    /// claimed: NE entries carry no uid, so "which user" is not ours
    /// to assert.
    case heldByForeign(name: String?)
}

/// The one place "is the slot held by someone else?" is decided. The
/// connection gate, the activation belts, and the DEBUG harness all
/// consume this same pure rule, so they can never drift apart.
///
/// Evidence doctrine, aligned with the ingest ownership boundary: a
/// verdict of "foreign" is only ever pronounced on positive proof —
/// an occupying session whose id the owner-scoped vault answers
/// `.missing` for ("scoping reads as absence": the daemon serves
/// another account's item as absent, so absence IS the attribution).
/// Everything unverifiable answers `.free`: blocking the operator on
/// evidence that never arrived would be worse than letting an
/// activation fail with the system's own error.
///
/// Scope: `loadAllFromPreferences` hands back only THIS app's
/// configurations (every local user's), so the classifier sees
/// cross-USER holders of this product — a third-party VPN holding the
/// slot is outside its sight and stays the activation belts' problem.
enum SlotClassifier {

    /// Statuses that occupy the exclusive slot. `reasserting` counts:
    /// the session is down but the system still owns the slot for it.
    private static func isOccupying(_ status: NEVPNStatus) -> Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    /// - Parameters:
    ///   - providers: the raw system-wide list (`loadAllFromPreferences`).
    ///   - ownedIDs: the ids the owner-scoped vault decoded for this user.
    ///   - probe: per-id vault read for ids outside `ownedIDs` — the
    ///     same disambiguation ingest uses (.missing = foreign,
    ///     .undecodable = ours-but-broken).
    static func classify(
        providers: [TunnelProviding],
        ownedIDs: Set<UUID>,
        probe: (UUID) async -> TunnelVaultClient.Read
    ) async -> SlotVerdict {
        for provider in providers {
            guard isOccupying(provider.connectionStatus) else { continue }
            guard let identity = provider.tunnelIdentity else {
                // Active but carrying no identity: one of this app's
                // entries with a broken projection — unattributable.
                // No proof of "foreign", so no verdict of it.
                continue
            }
            if ownedIDs.contains(identity.id) {
                // Our own session holds the slot — nothing to gate.
                continue
            }
            switch await probe(identity.id) {
            case .missing:
                // An empty label reads as no label — the gate copy
                // falls back to its unnamed variant instead of
                // rendering empty quotes.
                let name = provider.localizedDescription
                return .heldByForeign(name: name?.isEmpty == false ? name : nil)
            case .config, .undecodable:
                // Ours after all: stored after the readAll snapshot,
                // or ours with an unreadable payload (a custody
                // problem, not a stranger).
                continue
            case .unreachable:
                // Unverifiable — see the doctrine above.
                continue
            }
        }
        return .free
    }
}
