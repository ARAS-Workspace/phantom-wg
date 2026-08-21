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
// Vault Integrity — Teardown Arms
//
// The two cleanup arms that belong to THIS pass and could not be shared.
// The rest of the kit — three-valued reads, re-read-verified deletes and
// entry removals, the fresh-list probe and the repair arms — lives on the
// base as `TestWorkflow+VerifiedSweep.swift`, because every workflow that
// plants something owes the same honesty when it cleans up.
//
// These two stayed for reasons about the arms rather than about tidiness:
//
//   sweepThrowaways      reads this workflow's own planted ledgers
//                        (`tracked`, `rawIds`), so it has no meaning on a
//                        workflow that planted something else
//
//   sweepCorruptionBase  carries a doctrine that holds for exactly one
//                        base: its payload is deliberately corrupt,
//                        `readAll` never returns it, and therefore no
//                        restore can ever repair it — which is what makes
//                        taking the entry LAST correct here and wrong for
//                        a decodable row. Promoted, it would hand other
//                        workflows a reasoning that does not apply to them
//
// Both run on the promoted kit and obey the rule it carries: a cleanup
// that cannot VERIFY what it did reports residue rather than success, and
// no arm claims a state it did not observe.

#if DEBUG
import Foundation

// MARK: - The two teardown arms that belong to THIS pass and could not
extension VaultIntegrityWorkflow {
    func sweepCorruptionBase(_ base: TunnelContainer, id: UUID, name: String) async {
        var notes: [String] = []
        var stuck = false
        if let listed = tunnel(named: name) {
            do {
                try await tunnels.remove(tunnel: listed)
                notes.append("entry removed")
                switch await readPayloadState(id) {
                case .missing:
                    break
                case .present:
                    switch await verifiedDelete(id) {
                    case .swept:
                        notes.append("leftover payload swept")
                    case .sweptOnReread:
                        notes.append("leftover payload swept (verified gone on re-read)")
                    case .stillPresent:
                        notes.append("leftover payload still present")
                        stuck = true
                    case .unverified:
                        notes.append("vault unreachable — leftover payload state unverified")
                        stuck = true
                    }
                case .unreachable:
                    notes.append("vault unreachable — leftover payload state unverified")
                    stuck = true
                }
            } catch {
                let resolved = await resolveFailedRemove(listed, id: id, error: error)
                notes.append(contentsOf: resolved.notes)
                stuck = stuck || resolved.stuck
            }
        } else {
            switch await readPayloadState(id) {
            case .present:
                let verdict = await verifiedDelete(id)
                switch verdict {
                case .swept, .sweptOnReread:
                    notes.append(verdict == .sweptOnReread
                        ? "payload swept (verified gone on re-read)" : "payload swept")
                    switch await verifiedEntryRemoval(id: id, via: base.tunnelProvider) {
                    case .removed:
                        notes.append("hidden NE entry removed")
                        await tunnels.prune()
                    case .alreadyGone:
                        notes.append("hidden NE entry already gone")
                        await tunnels.prune()
                    case .failed:
                        notes.append("hidden NE entry removal failed — check System Settings > VPN")
                        stuck = true
                    case .unverified:
                        notes.append("hidden NE entry state unverified — system list unreadable")
                        stuck = true
                    }
                case .stillPresent:
                    notes.append("payload still present — hidden NE entry left in place so custody can resurface it")
                    stuck = true
                case .unverified:
                    notes.append("vault unreachable — payload state unverified; hidden NE entry left in place")
                    stuck = true
                }
            case .missing:
                let probe = await probeHiddenSurvivor(id: id)
                notes.append(contentsOf: probe.notes)
                stuck = stuck || probe.stuck
            case .unreachable:
                notes.append("vault unreachable — payload state unverified, entry (if any) left in place")
                stuck = true
            }
        }
        log("teardown: corruption base — \(notes.isEmpty ? "already clean" : notes.joined(separator: ", "))",
            stuck ? .error : (notes.isEmpty ? .info : .warn))
    }

    func sweepThrowaways() async {
        let ids = self.tracked.map(\.id) + self.rawIds
        guard !ids.isEmpty else {
            self.log("teardown: nothing was planted")
            return
        }
        var cleared = Set<UUID>()
        var swept = 0
        var stuck = 0
        var unverified = 0
        var unchecked = 0
        var index = 0
        var stuckStreak = 0
        payloadSweep: for id in ids {
            index += 1
            switch await self.vault.read(id: id) {
            case .missing:
                cleared.insert(id)
            case .unreachable:
                unchecked = ids.count - index + 1
                self.log("teardown: vault dark — swept \(swept), still present \(stuck), \(unchecked) of \(ids.count) left unchecked", .error)
                break payloadSweep
            case .config, .undecodable:
                if stuckStreak >= 2 {
                    stuck += 1
                    continue
                }
                switch await self.verifiedDelete(id) {
                case .swept, .sweptOnReread:
                    swept += 1
                    cleared.insert(id)
                    stuckStreak = 0
                case .stillPresent:
                    stuck += 1
                    stuckStreak += 1
                case .unverified:
                    unverified += 1
                    stuckStreak += 1
                }
            }
        }
        if unchecked == 0 {
            if swept == 0 && stuck == 0 && unverified == 0 {
                self.log("teardown: all \(ids.count) planted payload(s) already gone")
            } else {
                let unverifiedNote = unverified > 0 ? ", \(unverified) unverified (the store went dark on the re-read)" : ""
                self.log("teardown: swept \(swept), still present \(stuck)\(unverifiedNote), of \(ids.count) planted",
                         stuck > 0 || unverified > 0 ? .error : .warn)
            }
        }
        await self.sweepMintedEntries(cleared: cleared)
    }

    private func sweepMintedEntries(cleared: Set<UUID>) async {
            var entriesSwept = 0
            var entriesStuck = 0
            var entriesUnverified = 0
            var lookedClean = false
            for pass in 1...3 {
                if pass > 1 {
                    try? await Task.sleep(for: .milliseconds(800))
                }
                guard let fresh = try? await systemProviders.loadAllFromPreferences() else {
                    self.log("teardown: system list unreadable — minted-entry cleanliness unverified", .error)
                    return
                }
                let minted = fresh.filter { provider in
                    provider.tunnelIdentity.map { cleared.contains($0.id) } ?? false
                }
                if minted.isEmpty { lookedClean = true; break }
                lookedClean = false
                for provider in minted {
                    guard let id = provider.tunnelIdentity?.id else { continue }
                    switch await self.verifiedEntryRemoval(id: id, via: provider) {
                    case .removed, .alreadyGone: entriesSwept += 1
                    case .failed: entriesStuck += 1
                    case .unverified: entriesUnverified += 1
                    }
                }
                await self.tunnels.prune()
            }
            guard entriesSwept + entriesStuck + entriesUnverified > 0 else { return }
            var parts = ["\(entriesSwept) swept"]
            if entriesStuck > 0 { parts.append("\(entriesStuck) refused removal — check System Settings > VPN") }
            if entriesUnverified > 0 { parts.append("\(entriesUnverified) unverified (system list went unreadable)") }
            if !lookedClean { parts.append("last look still saw a cleared-id entry — a straggler may remain") }
            self.log("teardown: minted entries — \(parts.joined(separator: ", "))",
                     (entriesStuck + entriesUnverified) > 0 || !lookedClean ? .error : .warn)
    }
}
#endif
