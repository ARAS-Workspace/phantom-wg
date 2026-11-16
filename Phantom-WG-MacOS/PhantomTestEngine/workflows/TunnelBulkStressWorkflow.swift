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
// Tunnel Bulk Stress
//
// The gear menu's bulk import and the list's bulk delete under volume,
// driven through `TunnelBulkImport` and `TunnelBulkDelete` the way the app
// drives them, with the three stores a tunnel lives in read after every
// batch: the list, the system's entries and the vault's payloads. Every
// step ends on the same agreement: each tunnel is one id, held by all three
// stores or by none of them, and the report counts what the stores show.
// Each batch logs how long it took; the durations carry no verdict.
//
// This layer runs over fabricated stores, as Tunnel Transfer does: a vault
// that answers at once, records what it is given and reads back the payloads
// it holds, and a factory whose minted entries start at rest. Nothing
// reaches the user's list or the real vault.
//
// Scenarios:
//
//   A — A Full Archive Imports Whole And Deletes Whole
//       An archive of 500 .conf entries, the import's limit, every other one
//       a Ghost tunnel. All 500 are added in label order and the three
//       stores hold the same 500 ids, each payload the configuration its
//       entry carried. A bulk delete of every row takes all 500 in list
//       order and leaves none of the three stores holding anything. An
//       archive of 501 entries is refused whole and adds nothing.
//
//   B — A Delete And An Import That Overlap Keep Their Own Rows
//       200 tunnels (set A) are listed; a bulk delete of all of them starts
//       and, without waiting for it, a bulk import of a 200-entry archive
//       (set B). Every vault write and every entry save answers a
//       millisecond late, so the two batches take turns on the main actor.
//       The step first shows that they did overlap: B payloads were being
//       stored while the delete was still counting, a reading taken from
//       the vault so that it stands apart from the list under test. Then
//       the delete took all of A and nothing else, the import added all of
//       B, and the three stores hold exactly B's 200 ids, each payload the
//       configuration its entry carried.

#if DEBUG
import Foundation
import NetworkExtension

final class TunnelBulkStressWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Bulk Stress (Import And Remove)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("A Full Archive Imports Whole And Deletes Whole", aFullArchiveImportsWholeAndDeletesWhole),
            WorkflowStep("A Delete And An Import That Overlap Keep Their Own Rows", aDeleteAndAnImportThatOverlapKeepTheirOwnRows),
        ]
    }

    private struct Rig {
        let manager: TunnelsManager
        let vault: FaultVaultClient
        let entries: MintedProviderLedger
    }

    private struct Stores {
        let rows: [UUID]
        let entries: [UUID]
        let payloads: [UUID]

        var agree: Bool {
            Set(rows).count == rows.count
                && Set(entries).count == entries.count
                && Set(payloads).count == payloads.count
                && Set(rows) == Set(entries)
                && Set(rows) == Set(payloads)
        }

        var isEmpty: Bool { rows.isEmpty && entries.isEmpty && payloads.isEmpty }

        var line: String {
            "rows=\(rows.count), entries=\(entries.count), payloads=\(payloads.count), distinct ids=\(Set(rows + entries + payloads).count)"
        }
    }

    private struct Batch {
        let names: [String]
        let sources: [String: TunnelConfig]
        let archive: URL
    }

    @MainActor
    private final class Samples {
        var progress: [Int] = []
        var storedOfB: [Int] = []
    }

    private let archiveLimit = 500
    private let overlapSize = 200
    private let lateAnswer = 0.001
    private let runTag = String(UUID().uuidString.prefix(8))
    private var directory: URL?

    private func names(_ set: String, count: Int) -> [String] {
        (1...count).map { "TE-Stress-\(set)-\(String(format: "%04d", $0))-\(runTag)" }
    }

    // MARK: - Rig

    private func makeRig(answeringLate: Bool = false) -> Rig {
        let vault = FaultVaultClient()
        vault.readAllAnswer = .answers(.configs([]))
        vault.readAnswer = .answers(.missing)
        vault.storeAnswer = answeringLate ? .answersAfter(seconds: lateAnswer, .done) : .answers(.done)
        vault.deleteAnswer = answeringLate ? .answersAfter(seconds: lateAnswer, .done) : .answers(.done)
        let factory = FakeSlotFactory(canned: [])
        factory.minted.status = .disconnected
        if answeringLate {
            factory.minted.saveAnswer = .succeedsAfter(seconds: lateAnswer)
        }
        let manager = TunnelsManager(
            tunnelProviders: [],
            providerFactory: factory,
            vault: vault,
            observesSystemChanges: false
        )
        return Rig(manager: manager, vault: vault, entries: factory.minted)
    }

    private func readsBackWhatItHolds(_ rig: Rig) {
        let deleted = Set(rig.vault.deletedIds)
        for config in rig.vault.storedConfigs where !deleted.contains(config.id) {
            rig.vault.readAnswers[config.id] = .answers(.config(config))
        }
    }

    private func stores(_ rig: Rig) -> Stores {
        let deleted = Set(rig.vault.deletedIds)
        return Stores(
            rows: rig.manager.tunnels.map(\.id),
            entries: rig.entries.providers.filter(\.entryExists).compactMap { $0.storedIdentity?.id },
            payloads: rig.vault.storedIds.filter { !deleted.contains($0) }
        )
    }

    private func mismatchedPayloads(_ batch: Batch, in rig: Rig) -> [String] {
        let deleted = Set(rig.vault.deletedIds)
        var payloads: [String: TunnelConfig] = [:]
        for config in rig.vault.storedConfigs where !deleted.contains(config.id) && payloads[config.name] == nil {
            payloads[config.name] = config
        }
        return batch.names.filter { tunnelName in
            guard let source = batch.sources[tunnelName], let payload = payloads[tunnelName] else { return true }
            return payload.wireguard != source.wireguard || payload.wstunnel != source.wstunnel
        }
    }

    private func workDirectory() -> URL? {
        if let directory { return directory }
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-bulk-stress-\(runTag)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        onTeardown("stress folder") {
            try? FileManager.default.removeItem(at: made)
        }
        directory = made
        return made
    }

    private func writeBatch(_ names: [String], file: String, extra: String? = nil) -> Batch? {
        guard let folder = workDirectory() else { return nil }
        var sources: [String: TunnelConfig] = [:]
        var entries: [(String, Data)] = []
        for (index, tunnelName) in names.enumerated() {
            guard let config = TestConfigFactory.throwaway(name: tunnelName, ghost: index % 2 == 1) else { return nil }
            sources[tunnelName] = config
            entries.append(("batch/\(tunnelName).conf", TunnelConfFile.data(config.asConfString())))
        }
        if let extra, let first = entries.first {
            entries.append(("batch/\(extra).conf", first.1))
        }
        let archive = folder.appendingPathComponent(file)
        do {
            try ZipArchive.write(entries, to: archive)
        } catch {
            return nil
        }
        return Batch(names: names, sources: sources, archive: archive)
    }

    private static func timing(_ label: String, _ duration: Duration, count: Int) -> String {
        let total = milliseconds(duration)
        let each = total / Double(max(count, 1))
        return "\(label): \(String(format: "%.0f", total)) ms in all, \(String(format: "%.2f", each)) ms per tunnel (\(count))"
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    // MARK: - Step A

    private func aFullArchiveImportsWholeAndDeletesWhole() async {
        let full = names("Full", count: archiveLimit)
        guard let batch = writeBatch(full, file: "stress-\(archiveLimit).zip"),
              let overLimit = writeBatch(full, file: "stress-\(archiveLimit + 1).zip",
                                         extra: "TE-Stress-Full-\(archiveLimit + 1)-\(runTag)") else {
            fail("the \(archiveLimit)-entry archive and its \(archiveLimit + 1)-entry twin could not be written")
            return
        }
        let rig = makeRig()
        await importsWhole(batch, into: rig)
        await deletesWhole(from: rig)
        await refusesOverLimit(overLimit.archive)
    }

    private func importsWhole(_ batch: Batch, into rig: Rig) async {
        let started = ContinuousClock.now
        let report = await TunnelBulkImport.run([batch.archive], into: rig.manager)
        log(Self.timing("import", ContinuousClock.now - started, count: report.added.count))

        check(report.added == batch.names && report.skipped.isEmpty,
              "every entry of the \(archiveLimit)-entry archive was added, in label order, and nothing was reported (added=\(report.added.count), skipped=\(report.skipped.count))")

        let held = stores(rig)
        let listed = Set(rig.manager.tunnels.map(\.name))
        check(held.agree && held.rows.count == archiveLimit && listed == Set(batch.names),
              "the list, the system's entries and the vault hold the same \(archiveLimit) ids, each once (\(held.line))")

        let mismatched = mismatchedPayloads(batch, in: rig)
        check(mismatched.isEmpty,
              "every payload is the configuration its entry carried, the Ghost half with its Wstunnel part (mismatched=\(mismatched.count))")

        let painted = Dictionary(grouping: rig.manager.tunnels) { "\($0.status)" }.mapValues(\.count)
        log("rows painted after the import: \(painted.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
    }

    private func deletesWhole(from rig: Rig) async {
        readsBackWhatItHolds(rig)
        let rows = TunnelListRules.ordered(rig.manager.tunnels, saved: [], id: \.id)
        let targets = TunnelBulkDelete.targets(rows, marked: Set(rows.map(\.id)))
        var progress: [Int] = []
        let started = ContinuousClock.now
        let report = await TunnelBulkDelete.run(targets, in: rig.manager) { progress.append($0) }
        log(Self.timing("delete", ContinuousClock.now - started, count: targets.count))

        check(!targets.isEmpty
                && report.deleted == targets.map(\.name)
                && report.skipped.isEmpty
                && progress == Array(1...targets.count),
              "the bulk delete took every row in list order, skipped none and counted each once (targets=\(targets.count), deleted=\(report.deleted.count), skipped=\(report.skipped.count), progress last=\(progress.last ?? 0))")

        let left = stores(rig)
        let removedOnce = rig.entries.providers.allSatisfy { $0.removeCount == 1 }
        check(left.isEmpty && removedOnce,
              "none of the three stores holds anything and each entry was removed once (\(left.line), removed once \(removedOnce))")
    }

    private func refusesOverLimit(_ archive: URL) async {
        let rig = makeRig()
        let report = await TunnelBulkImport.run([archive], into: rig.manager)
        let held = stores(rig)
        check(report.added.isEmpty
                && report.skipped.map(\.skip) == [.archiveTooManyEntries]
                && held.isEmpty,
              "an archive of \(archiveLimit + 1) entries is refused whole and adds nothing (added=\(report.added.count), skipped=\(report.skipped.map { "\($0.skip)" }), \(held.line))")
    }

    // MARK: - Step B

    private func aDeleteAndAnImportThatOverlapKeepTheirOwnRows() async {
        let setA = names("A", count: overlapSize)
        let setB = names("B", count: overlapSize)
        guard let batchB = writeBatch(setB, file: "overlap-b-\(overlapSize).zip") else {
            fail("the \(overlapSize)-entry archive for set B could not be written")
            return
        }
        let rig = makeRig(answeringLate: true)
        for tunnelName in setA {
            guard let config = TestConfigFactory.throwaway(name: tunnelName) else {
                fail("the config factory did not produce \(tunnelName)")
                return
            }
            do {
                _ = try await rig.manager.add(config: config)
            } catch {
                fail("set A could not be listed: \(tunnelName) — \(error.localizedDescription)")
                return
            }
        }
        readsBackWhatItHolds(rig)
        let rows = TunnelListRules.ordered(rig.manager.tunnels, saved: [], id: \.id)
        let targets = TunnelBulkDelete.targets(rows, marked: Set(rows.map(\.id)))
        guard targets.count == setA.count, Set(targets.map(\.name)) == Set(setA) else {
            fail("set A is not the whole list (targets=\(targets.count))")
            return
        }
        await overlaps(targets, with: batchB, in: rig)
    }

    private func overlaps(_ targets: [TunnelContainer], with batchB: Batch, in rig: Rig) async {
        let namesB = Set(batchB.names)
        let manager = rig.manager
        let vault = rig.vault
        let seen = Samples()
        let started = ContinuousClock.now
        let deleting = Task { @MainActor in
            let report = await TunnelBulkDelete.run(targets, in: manager) { done in
                seen.progress.append(done)
                seen.storedOfB.append(vault.storedConfigs.filter { namesB.contains($0.name) }.count)
            }
            return (report, ContinuousClock.now - started)
        }
        let importing = Task { @MainActor in
            let report = await TunnelBulkImport.run([batchB.archive], into: manager)
            return (report, ContinuousClock.now - started)
        }
        let (deleted, deleteTook) = await deleting.value
        let (imported, importTook) = await importing.value
        log(Self.timing("delete of set A, from the common start", deleteTook, count: targets.count))
        log(Self.timing("import of set B, from the common start", importTook, count: imported.added.count))

        let midway = seen.storedOfB.filter { $0 > 0 && $0 < overlapSize }
        check(!midway.isEmpty,
              "the two batches overlapped: set B payloads were being stored while the delete was counting (B payloads stored at the delete's progress: first \(seen.storedOfB.first ?? -1), last \(seen.storedOfB.last ?? -1), midway samples \(midway.count) of \(seen.storedOfB.count))")

        check(deleted.deleted == targets.map(\.name)
                && deleted.skipped.isEmpty
                && seen.progress == Array(1...targets.count),
              "the delete took every row of set A in list order, skipped none and counted each once (deleted=\(deleted.deleted.count), skipped=\(deleted.skipped.count), progress last=\(seen.progress.last ?? 0))")

        check(imported.added == batchB.names && imported.skipped.isEmpty,
              "the import added every entry of set B in label order and reported nothing (added=\(imported.added.count), skipped=\(imported.skipped.count))")

        let held = stores(rig)
        let listed = rig.manager.tunnels.map(\.name)
        check(held.agree && held.rows.count == overlapSize && Set(listed) == namesB,
              "the list, the system's entries and the vault hold exactly set B's \(overlapSize) ids, each once, and nothing of set A (\(held.line), set A rows left \(listed.filter { !namesB.contains($0) }.count))")

        let mismatched = mismatchedPayloads(batchB, in: rig)
        check(mismatched.isEmpty,
              "every set B payload is the configuration its entry carried (mismatched=\(mismatched.count))")
    }
}
#endif
