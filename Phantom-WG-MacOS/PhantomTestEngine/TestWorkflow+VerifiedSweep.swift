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
// Test Engine: Verified Sweep Kit
//
// Cleanup that reports what it could not verify, rather than what it
// attempted. On the base class because every workflow that plants
// something owes the same honesty when it takes it back — and because a
// cleanup that answers `true` on silence is how a suite leaves residue on
// a user's machine and calls the run green.
//
// The kit is three-valued everywhere it can be:
//
//   PayloadReading   present · missing · unreachable
//   SweepVerdict     swept · sweptOnReread · stillPresent · unverified
//   EntryRemoval     removed · alreadyGone · failed · unverified
//
// `unreachable` and `unverified` are the cases that make it worth having:
// a vault that stopped answering is not an empty vault, and a delete that
// went unanswered is not a delete that landed.
//
// Members:
//
//   readPayloadState        three-valued read
//   verifiedDelete          delete; on a refusal or a silence, re-read
//                           before deciding whether it landed
//   verifiedEntryRemoval    remove the system entry; if the removal threw,
//                           re-read the list before believing it
//   probeHiddenSurvivor     ask a FRESH system list whether an entry the
//                           mirror lost is still there
//   sweepOrphanedPayload    repair arm: payload without its entry
//   resolveFailedRemove     repair arm: entry whose removal was refused
//   sweepPlantedTunnel      the full path, spent on one planted tunnel

#if DEBUG
import Foundation

// MARK: - The verified-sweep kit: three-valued reads, re-read-verified
extension TestWorkflow {
    enum PayloadReading { case present, missing, unreachable }

    func readPayloadState(_ id: UUID) async -> PayloadReading {
        switch await vault.read(id: id, attempts: 3) {
        case .missing: return .missing
        case .unreachable: return .unreachable
        default: return .present
        }
    }

    enum SweepVerdict { case swept, sweptOnReread, stillPresent, unverified }

    func verifiedDelete(_ id: UUID) async -> SweepVerdict {
        switch await vault.delete(id: id, attempts: 3) {
        case .done:
            return .swept
        case .refused, .unreachable:
            switch await vault.read(id: id) {
            case .missing: return .sweptOnReread
            case .unreachable: return .unverified
            default: return .stillPresent
            }
        }
    }

    enum EntryRemoval { case removed, alreadyGone, failed, unverified }

    func verifiedEntryRemoval(id: UUID, via provider: TunnelProviding) async -> EntryRemoval {
        if (try? await provider.removePreferences()) != nil { return .removed }
        try? await Task.sleep(for: .milliseconds(600))
        guard let fresh = try? await systemProviders.loadAllFromPreferences() else {
            return .unverified
        }
        return fresh.contains(where: { $0.tunnelIdentity?.id == id }) ? .failed : .alreadyGone
    }

    func probeHiddenSurvivor(id: UUID) async -> (notes: [String], stuck: Bool) {
        guard let fresh = try? await systemProviders.loadAllFromPreferences() else {
            return (["system list unreadable — entry cleanliness unverified"], true)
        }
        guard let survivor = fresh.first(where: { $0.tunnelIdentity?.id == id }) else {
            if tunnels.tunnels.contains(where: { $0.id == id }) {
                await tunnels.prune()
            }
            return ([], false)
        }
        switch await verifiedEntryRemoval(id: id, via: survivor) {
        case .removed:
            await tunnels.prune()
            return (["surviving NE entry removed (a half-completed removal had left it behind)"], false)
        case .alreadyGone:
            await tunnels.prune()
            return (["surviving NE entry already gone by the time it was acted on"], false)
        case .failed:
            return (["surviving NE entry removal failed — check System Settings > VPN"], true)
        case .unverified:
            return (["surviving NE entry removal unverified — system list went unreadable"], true)
        }
    }

    func sweepOrphanedPayload(id: UUID, error: Error) async -> (notes: [String], stuck: Bool) {
        let verdict = await verifiedDelete(id)
        var notes: [String] = []
        var stuck = false
        switch verdict {
        case .swept, .sweptOnReread:
            notes.append(verdict == .sweptOnReread
                ? "payload swept (an entry-first removal had left it with no entry, verified gone on re-read)"
                : "payload swept (an entry-first removal had left it with no entry)")
        case .stillPresent:
            notes.append("orphan payload still present after a verified sweep — a restore will re-mint it (\(error.localizedDescription))")
            stuck = true
        case .unverified:
            notes.append("orphan payload sweep unverified — vault went dark (\(error.localizedDescription))")
            stuck = true
        }

        guard let after = try? await systemProviders.loadAllFromPreferences() else {
            notes.append("entry state after the sweep unverified — system list went unreadable")
            return (notes, true)
        }
        if let arrived = after.first(where: { $0.tunnelIdentity?.id == id }) {
            switch await verifiedEntryRemoval(id: id, via: arrived) {
            case .removed:
                notes.append("a restore had minted an entry into the sweep's window; it was removed")
            case .alreadyGone:
                notes.append("a restore's entry appeared and was gone again by the time it was acted on")
            case .failed:
                notes.append("a restore minted an entry into the sweep's window and it would not come down — check System Settings > VPN")
                stuck = true
            case .unverified:
                notes.append("a restore minted an entry into the sweep's window and its removal is unverified")
                stuck = true
            }
        }
        if tunnels.tunnels.contains(where: { $0.id == id }) {
            await tunnels.prune()
        }
        return (notes, stuck)
    }

    func resolveFailedRemove(_ listed: TunnelContainer, id: UUID, error: Error) async -> (notes: [String], stuck: Bool) {
        switch await readPayloadState(id) {
        case .present:
            try? await Task.sleep(for: .milliseconds(800))
            guard let fresh = try? await systemProviders.loadAllFromPreferences() else {
                return (["payload present, entry unverifiable — system list went unreadable (\(error.localizedDescription))"], true)
            }
            guard !fresh.contains(where: { $0.tunnelIdentity?.id == id }) else {
                return (["entry still listed, payload intact — visible custody kept (\(error.localizedDescription))"], true)
            }
            return await sweepOrphanedPayload(id: id, error: error)
        case .missing:
            switch await verifiedEntryRemoval(id: id, via: listed.tunnelProvider) {
            case .removed:
                await tunnels.prune()
                return (["remove() half-completed (payload gone) — entry taken down"], false)
            case .alreadyGone:
                await tunnels.prune()
                return (["remove() half-completed (payload gone) — entry already gone"], false)
            case .failed:
                return (["remove() half-completed (payload gone) and the entry refused removal — check System Settings > VPN"], true)
            case .unverified:
                return (["remove() half-completed (payload gone), entry state unverified — system list unreadable"], true)
            }
        case .unreachable:
            return (["remove() failed (\(error.localizedDescription)) and the vault is unreachable — which half survived is unverified, pair left in place"], true)
        }
    }

    func sweepPlantedTunnel(id: UUID, name: String) async {
        var notes: [String] = []
        var stuck = false

        if let listed = tunnel(named: name) {
            if listed.status != .inactive {
                tunnels.startDeactivation(of: listed)
                guard await awaitStatus(listed, is: .inactive, within: 15) else {
                    log("teardown: \(name) would not ground (status=\(listed.status)) — left in the list on purpose", .error)
                    return
                }
            }
            var removeError: Error?
            do { try await tunnels.remove(tunnel: listed) } catch { removeError = error }
            if case TunnelManagementError.vaultUnavailable? = removeError {
                var answered = false
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    if case .ready = await vault.ping() { answered = true; break }
                    try? await Task.sleep(for: .seconds(1))
                }
                if let again = tunnel(named: name) {
                    do { try await tunnels.remove(tunnel: again); removeError = nil } catch { removeError = error }
                } else if answered {
                    removeError = nil
                }
            }
            if let removeError {
                notes.append("remove refused (\(removeError.localizedDescription))")
                stuck = true
            }
        }

        var payloadGone = false
        switch await readPayloadState(id) {
        case .missing:
            payloadGone = true
        case .present:
            switch await verifiedDelete(id) {
            case .swept, .sweptOnReread:
                notes.append("payload swept")
                payloadGone = true
            case .stillPresent:
                notes.append("payload still in the vault after a verified sweep")
                stuck = true
            case .unverified:
                notes.append("payload sweep unverified — the vault went dark")
                stuck = true
            }
        case .unreachable:
            notes.append("payload state unverified — the vault did not answer")
            stuck = true
        }

        if payloadGone {
            let (entryNotes, entryStuck) = await probeHiddenSurvivor(id: id)
            notes.append(contentsOf: entryNotes)
            stuck = stuck || entryStuck
        } else {
            notes.append("entry left in place — its payload was not observed gone, so it is still the anchor")
        }

        log("teardown: \(name) — \(notes.isEmpty ? "both stores clean" : notes.joined(separator: ", "))",
            stuck ? .error : (notes.isEmpty ? .info : .warn))
    }

}
#endif
