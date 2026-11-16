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
// Tunnel Bulk Stress (Faults)
//
// The third part of Tunnel Bulk Stress: a fault in the middle of a bulk
// import or a bulk delete, driven through `TunnelBulkImport` and
// `TunnelBulkDelete` into a tunnel manager over fabricated stores. The vault
// and the system's entries answer at once except where a step names a
// fault. The stores are read from the rows, the entries the fake system
// still holds and the payloads the fake vault holds after the writes it
// answered done (`FaultVaultClient.held`).
//
// A fault the vault or the system answers touches only its own tunnel: the
// batch reports it with its reason and goes on. A vault that cannot be
// reached for three tunnels in a row stops the batch, and the tunnels after
// it are reported as not attempted. A fault on the vault's side costs the
// manager's three-attempt ladder, about 1.8 s; each batch logs how long it
// took, with no verdict.
//
// Scenarios, each over ten tunnels:
//
//   A — A Fault In A Delete Touches Only Its Tunnel
//       Three faults of three kinds in a row: the vault cannot be reached
//       for the third tunnel's payload read, it refuses the fourth's payload
//       delete, and the system refuses the fifth's entry removal. Only the
//       first is the vault going unanswered, so the batch goes on: the other
//       seven are deleted in list order, each fault is reported with its own
//       reason, and the progress counts all ten. The third and the fifth
//       stand in all three stores; the fourth lost its entry first and keeps
//       its row and its payload for the restore.
//
//   B — A Fault In An Import Touches Only Its Tunnel
//       Three faults in a row that the vault and the system answer: the
//       system refuses the third candidate's entry save, refuses the
//       fourth's as well while the vault refuses that one's rollback delete,
//       and the vault refuses the fifth's payload. The other seven are added
//       in label order. The third and the fifth leave nothing behind; the
//       fourth leaves a payload with no entry and no row.
//
//   C — A Dark Vault Stops A Delete After Three Tunnels
//       The vault goes dark after the third payload delete. The fourth,
//       fifth and sixth are reported unreachable, the last four as not
//       attempted, and the progress still counts all ten. The seven left
//       stand whole in all three stores.
//
//   D — A Dark Vault Stops An Import After Three Tunnels
//       The vault goes dark after the third stored payload. The fourth,
//       fifth and sixth candidates are reported unreachable, the last four
//       as not attempted, and only the first three are held anywhere.
//
//   E — A Vault That Comes Back Lets The Batch Carry On
//       In a delete, the vault cannot be reached for the third, fourth and
//       sixth tunnels' payload reads: two in a row, an answer, then one. In
//       an import, the same three candidates' payload stores go unreachable.
//       Neither batch stops: seven are deleted, seven are added, and the
//       three reported are reported unreachable, none as not attempted.

#if DEBUG
import Foundation
import NetworkExtension

final class TunnelBulkStressFaultWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Bulk Stress (Faults)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("A Fault In A Delete Touches Only Its Tunnel", aFaultInADeleteTouchesOnlyItsTunnel),
            WorkflowStep("A Fault In An Import Touches Only Its Tunnel", aFaultInAnImportTouchesOnlyItsTunnel),
            WorkflowStep("A Dark Vault Stops A Delete After Three Tunnels", aDarkVaultStopsADeleteAfterThreeTunnels),
            WorkflowStep("A Dark Vault Stops An Import After Three Tunnels", aDarkVaultStopsAnImportAfterThreeTunnels),
            WorkflowStep("A Vault That Comes Back Lets The Batch Carry On", aVaultThatComesBackLetsTheBatchCarryOn),
        ]
    }

    private struct Rig {
        let manager: TunnelsManager
        let vault: FaultVaultClient
        let entries: MintedProviderLedger
    }

    private struct Batch {
        let names: [String]
        let archive: URL
    }

    private struct Standing {
        let rows: Set<String>
        let entries: Set<String>
        let payloads: Set<String>

        var line: String { "rows=\(rows.count), entries=\(entries.count), payloads=\(payloads.count)" }
    }

    private let batchSize = 10
    private let runTag = String(UUID().uuidString.prefix(8))
    private var directory: URL?
    private let refusal = NSError(domain: "TE.BulkFault", code: 1, userInfo: [NSLocalizedDescriptionKey: "the fake system refused it"])

    private var unreachable: String { TunnelManagementError.vaultUnavailable.localizedDescription }
    private var refused: String { TunnelManagementError.vaultRefused.localizedDescription }
    private var additionRefused: String { TunnelManagementError.vpnSystemErrorOnAddTunnel(systemError: refusal).localizedDescription }
    private var removalRefused: String { TunnelManagementError.vpnSystemErrorOnRemoveTunnel(systemError: refusal).localizedDescription }

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

    private func standing(_ rig: Rig) -> Standing {
        Standing(
            rows: Set(rig.manager.tunnels.map(\.name)),
            entries: Set(rig.entries.providers.filter(\.entryExists).compactMap { $0.storedIdentity?.name }),
            payloads: Set(rig.vault.held.values.map(\.name))
        )
    }

    private func workDirectory() -> URL? {
        if let directory { return directory }
        let made = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnel-bulk-fault-\(runTag)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        onTeardown("fault folder") {
            try? FileManager.default.removeItem(at: made)
        }
        directory = made
        return made
    }

    private func batch(_ set: String) -> Batch? {
        guard let folder = workDirectory() else { return nil }
        let names = (1...batchSize).map { "TE-StressFault-\(set)-\(String(format: "%02d", $0))-\(runTag)" }
        var files: [(String, Data)] = []
        for (index, tunnelName) in names.enumerated() {
            guard let config = TestConfigFactory.throwaway(name: tunnelName, ghost: index % 2 == 1) else { return nil }
            files.append(("batch/\(tunnelName).conf", TunnelConfFile.data(config.asConfString())))
        }
        let archive = folder.appendingPathComponent("fault-\(set).zip")
        do {
            try ZipArchive.write(files, to: archive)
        } catch {
            return nil
        }
        return Batch(names: names, archive: archive)
    }

    private func listed(_ set: String, in rig: Rig) async -> [TunnelContainer]? {
        guard let batch = batch(set) else {
            fail("the \(batchSize)-entry archive to list could not be written")
            return nil
        }
        let report = await TunnelBulkImport.run([batch.archive], into: rig.manager)
        let rows = TunnelListRules.ordered(rig.manager.tunnels, saved: [], id: \.id)
        let targets = TunnelBulkDelete.targets(rows, marked: Set(rows.map(\.id)))
        guard report.added.count == batchSize, targets.count == batchSize else {
            fail("the \(batchSize) tunnels to delete could not be listed (added=\(report.added.count), targets=\(targets.count))")
            return nil
        }
        return targets
    }

    private func deleting(_ targets: [TunnelContainer], in rig: Rig) async -> (report: TunnelBulkDelete.Report, progress: [Int]) {
        var progress: [Int] = []
        let started = ContinuousClock.now
        let report = await TunnelBulkDelete.run(targets, in: rig.manager) { progress.append($0) }
        log("delete: \(Self.milliseconds(ContinuousClock.now - started)) ms for \(targets.count) tunnels")
        return (report, progress)
    }

    private func importing(_ batch: Batch, into rig: Rig) async -> TunnelBulkImport.Report {
        let started = ContinuousClock.now
        let report = await TunnelBulkImport.run([batch.archive], into: rig.manager)
        log("import: \(Self.milliseconds(ContinuousClock.now - started)) ms for \(batch.names.count) candidates")
        return report
    }

    private func skips(_ report: TunnelBulkImport.Report, are expected: [(name: String, skip: TunnelImportBatch.Skip)]) -> Bool {
        report.skipped.count == expected.count
            && zip(report.skipped, expected).allSatisfy { $0.label.hasSuffix("\($1.name).conf") && $0.skip == $1.skip }
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.0f", Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
    }

    private func short(_ text: String) -> String {
        let bare = text.hasSuffix(".conf") ? String(text.dropLast(5)) : text
        return String(bare.dropLast(runTag.count + 1).suffix(2))
    }

    private func word(_ message: String) -> String {
        switch message {
        case unreachable: return "unreachable"
        case refused: return "refused"
        case additionRefused, removalRefused: return "system refused"
        default: return message
        }
    }

    private func line(_ report: TunnelBulkDelete.Report) -> String {
        report.skipped.map { skipped -> String in
            switch skipped.skip {
            case .connected: return "\(short(skipped.name)) connected"
            case .failed(let message): return "\(short(skipped.name)) \(word(message))"
            case .notAttempted: return "\(short(skipped.name)) not attempted"
            }
        }.joined(separator: ", ")
    }

    private func line(_ report: TunnelBulkImport.Report) -> String {
        report.skipped.map { skipped -> String in
            switch skipped.skip {
            case .addFailed(let message): return "\(short(skipped.label)) \(word(message))"
            case .notAttempted: return "\(short(skipped.label)) not attempted"
            default: return "\(short(skipped.label)) \(skipped.skip)"
            }
        }.joined(separator: ", ")
    }

    // MARK: - Step A

    private func aFaultInADeleteTouchesOnlyItsTunnel() async {
        let rig = makeRig()
        guard let targets = await listed("Delete", in: rig) else { return }
        let unread = targets[2]
        let undeleted = targets[3]
        let unremoved = targets[4]
        rig.vault.readAnswers[unread.id] = .answers(.unreachable)
        rig.vault.deleteAnswersByName[undeleted.name] = .answers(.refused)
        (unremoved.tunnelProvider as? FakeSlotProvider)?.removeAnswer = .fails(refusal)
        let faulted: Set<String> = [unread.name, undeleted.name, unremoved.name]

        let (report, progress) = await deleting(targets, in: rig)
        let expected = [
            TunnelBulkDelete.Skipped(name: unread.name, skip: .failed(unreachable)),
            TunnelBulkDelete.Skipped(name: undeleted.name, skip: .failed(refused)),
            TunnelBulkDelete.Skipped(name: unremoved.name, skip: .failed(removalRefused)),
        ]
        check(report.deleted == targets.map(\.name).filter { !faulted.contains($0) }
                && report.skipped == expected
                && progress == Array(1...targets.count),
              "the other seven were deleted in list order and each fault was reported with its own reason, the progress counting all ten (deleted=\(report.deleted.count), skipped=[\(line(report))], progress last=\(progress.last ?? 0))")

        let after = standing(rig)
        check(after.rows == faulted
                && after.entries == [unread.name, unremoved.name]
                && after.payloads == faulted,
              "the unread and the unremoved tunnel stand in all three stores, the undeleted one lost its entry first and keeps its row and its payload for the restore, and nothing else is left (\(after.line))")
    }

    // MARK: - Step B

    private func aFaultInAnImportTouchesOnlyItsTunnel() async {
        guard let batch = batch("Import") else {
            fail("the \(batchSize)-entry archive could not be written")
            return
        }
        let rig = makeRig()
        let unsaved = batch.names[2]
        let stranded = batch.names[3]
        let unstored = batch.names[4]
        rig.entries.saveAnswers[3] = .fails(refusal)
        rig.entries.saveAnswers[4] = .fails(refusal)
        rig.vault.deleteAnswersByName[stranded] = .answers(.refused)
        rig.vault.storeAnswersByName[unstored] = .answers(.refused)
        let faulted: Set<String> = [unsaved, stranded, unstored]

        let report = await importing(batch, into: rig)
        check(report.added == batch.names.filter { !faulted.contains($0) }
                && skips(report, are: [
                    (unsaved, .addFailed(additionRefused)),
                    (stranded, .addFailed(additionRefused)),
                    (unstored, .addFailed(refused)),
                ]),
              "the other seven were added in label order and each fault was reported with its own reason (added=\(report.added.count), skipped=[\(line(report))])")

        let after = standing(rig)
        let added = Set(report.added)
        check(after.rows == added && after.entries == added && after.payloads == added.union([stranded]),
              "the unsaved and the unstored candidate left nothing behind, and the one whose rollback was refused left a payload with no entry and no row (\(after.line))")
    }

    // MARK: - Step C

    private func aDarkVaultStopsADeleteAfterThreeTunnels() async {
        let rig = makeRig()
        guard let targets = await listed("DarkDelete", in: rig) else { return }
        rig.vault.goesDarkAfterDeletes = 3
        let names = targets.map(\.name)

        let (report, progress) = await deleting(targets, in: rig)
        let expected = names[3..<6].map { TunnelBulkDelete.Skipped(name: $0, skip: .failed(unreachable)) }
            + names[6...].map { TunnelBulkDelete.Skipped(name: $0, skip: .notAttempted) }
        check(report.deleted == Array(names[..<3])
                && report.skipped == expected
                && progress == Array(1...targets.count),
              "three were deleted before the vault went dark, the next three were reported unreachable, the last four as not attempted, and the progress still counted all ten (deleted=\(report.deleted.count), skipped=[\(line(report))], progress last=\(progress.last ?? 0))")

        let after = standing(rig)
        let kept = Set(names[3...])
        check(after.rows == kept && after.entries == kept && after.payloads == kept,
              "the seven it did not delete stand whole in all three stores (\(after.line))")
    }

    // MARK: - Step D

    private func aDarkVaultStopsAnImportAfterThreeTunnels() async {
        guard let batch = batch("DarkImport") else {
            fail("the \(batchSize)-entry archive could not be written")
            return
        }
        let rig = makeRig()
        rig.vault.goesDarkAfterStores = 3
        let names = batch.names

        let report = await importing(batch, into: rig)
        let expected = names[3..<6].map { (name: $0, skip: TunnelImportBatch.Skip.addFailed(unreachable)) }
            + names[6...].map { (name: $0, skip: TunnelImportBatch.Skip.notAttempted) }
        check(report.added == Array(names[..<3]) && skips(report, are: expected),
              "three were added before the vault went dark, the next three were reported unreachable and the last four as not attempted (added=\(report.added.count), skipped=[\(line(report))])")

        let after = standing(rig)
        let added = Set(names[..<3])
        check(after.rows == added && after.entries == added && after.payloads == added,
              "only the three added are held anywhere (\(after.line))")
    }

    // MARK: - Step E

    private func aVaultThatComesBackLetsTheBatchCarryOn() async {
        let rig = makeRig()
        guard let targets = await listed("WindowDelete", in: rig) else { return }
        let gaps = [targets[2], targets[3], targets[5]]
        for gap in gaps {
            rig.vault.readAnswers[gap.id] = .answers(.unreachable)
        }
        let gapNames = Set(gaps.map(\.name))
        let (deleted, progress) = await deleting(targets, in: rig)
        check(deleted.deleted == targets.map(\.name).filter { !gapNames.contains($0) }
                && deleted.skipped == gaps.map { TunnelBulkDelete.Skipped(name: $0.name, skip: .failed(unreachable)) }
                && progress == Array(1...targets.count),
              "a delete whose vault went unreachable for two tunnels in a row, answered, then went unreachable for one more did not stop: seven deleted, the three reported unreachable (deleted=\(deleted.deleted.count), skipped=[\(line(deleted))])")

        guard let batch = batch("WindowImport") else {
            fail("the \(batchSize)-entry archive could not be written")
            return
        }
        let importRig = makeRig()
        let missed = [batch.names[2], batch.names[3], batch.names[5]]
        for name in missed {
            importRig.vault.storeAnswersByName[name] = .answers(.unreachable)
        }
        let imported = await importing(batch, into: importRig)
        check(imported.added == batch.names.filter { !missed.contains($0) }
                && skips(imported, are: missed.map { (name: $0, skip: .addFailed(unreachable)) }),
              "an import whose vault went unreachable the same way did not stop either: seven added, the three reported unreachable (added=\(imported.added.count), skipped=[\(line(imported))])")
    }
}
#endif
