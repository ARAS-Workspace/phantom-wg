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

#if DEBUG
import Foundation
import NetworkExtension

final class TunnelBulkStressWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Bulk Stress (Import And Remove)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("A Full Archive Imports Whole And Deletes Whole", aFullArchiveImportsWholeAndDeletesWhole),
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
        let overLimit: URL
    }

    private let archiveLimit = 500
    private let runTag = String(UUID().uuidString.prefix(8))
    private var directory: URL?

    private func name(_ index: Int) -> String { "TE-Stress-\(String(format: "%04d", index))-\(runTag)" }

    // MARK: - Rig

    private func makeRig() -> Rig {
        let vault = FaultVaultClient()
        vault.readAllAnswer = .answers(.configs([]))
        vault.readAnswer = .answers(.missing)
        vault.storeAnswer = .answers(.done)
        vault.deleteAnswer = .answers(.done)
        let factory = FakeSlotFactory(canned: [])
        factory.minted.status = .disconnected
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

    private func writeBatch(count: Int) -> Batch? {
        guard let folder = workDirectory() else { return nil }
        let names = (1...count).map(name)
        var sources: [String: TunnelConfig] = [:]
        var entries: [(String, Data)] = []
        for (index, tunnelName) in names.enumerated() {
            guard let config = TestConfigFactory.throwaway(name: tunnelName, ghost: index % 2 == 1) else { return nil }
            sources[tunnelName] = config
            entries.append(("batch/\(tunnelName).conf", TunnelConfFile.data(config.asConfString())))
        }
        guard let first = entries.first else { return nil }
        let archive = folder.appendingPathComponent("stress-\(count).zip")
        let overLimit = folder.appendingPathComponent("stress-\(count + 1).zip")
        do {
            try ZipArchive.write(entries, to: archive)
            try ZipArchive.write(entries + [("batch/\(name(count + 1)).conf", first.1)], to: overLimit)
        } catch {
            return nil
        }
        return Batch(names: names, sources: sources, archive: archive, overLimit: overLimit)
    }

    private static func timing(_ label: String, _ duration: Duration, count: Int) -> String {
        let parts = duration.components
        let total = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        let each = total / Double(max(count, 1))
        return "\(label): \(String(format: "%.0f", total)) ms in all, \(String(format: "%.2f", each)) ms per tunnel (\(count))"
    }

    // MARK: - Steps

    private func aFullArchiveImportsWholeAndDeletesWhole() async {
        guard let batch = writeBatch(count: archiveLimit) else {
            fail("the \(archiveLimit)-entry archive and its \(archiveLimit + 1)-entry twin could not be written")
            return
        }
        let rig = makeRig()
        await importsWhole(batch, into: rig)
        await deletesWhole(batch, from: rig)
        await refusesOverLimit(batch)
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

        var payloads: [String: TunnelConfig] = [:]
        for config in rig.vault.storedConfigs where payloads[config.name] == nil {
            payloads[config.name] = config
        }
        let mismatched = batch.names.filter { tunnelName in
            guard let source = batch.sources[tunnelName], let payload = payloads[tunnelName] else { return true }
            return payload.wireguard != source.wireguard || payload.wstunnel != source.wstunnel
        }
        check(mismatched.isEmpty,
              "every payload is the configuration its entry carried, the Ghost half with its Wstunnel part (mismatched=\(mismatched.count))")

        let painted = Dictionary(grouping: rig.manager.tunnels) { "\($0.status)" }.mapValues(\.count)
        log("rows painted after the import: \(painted.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
    }

    private func deletesWhole(_ batch: Batch, from rig: Rig) async {
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

    private func refusesOverLimit(_ batch: Batch) async {
        let rig = makeRig()
        let report = await TunnelBulkImport.run([batch.overLimit], into: rig.manager)
        let held = stores(rig)
        check(report.added.isEmpty
                && report.skipped.map(\.skip) == [.archiveTooManyEntries]
                && held.isEmpty,
              "an archive of \(archiveLimit + 1) entries is refused whole and adds nothing (added=\(report.added.count), skipped=\(report.skipped.map { "\($0.skip)" }), \(held.line))")
    }
}
#endif
