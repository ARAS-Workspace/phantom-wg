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
// Tunnel Bulk Delete
//
// The tunnel list's delete mode, driven through `TunnelBulkDelete` the way
// the list drives it, without the confirmation dialog and the device owner
// prompt around it.
//
// Everything here runs over fabricated stores, as Tunnel Transfer does: a
// vault that answers at once and holds a payload for every row, and fake
// providers whose status and removal answer each step sets. Nothing reaches
// the user's list or the real vault.
//
// Scenarios:
//
//   A — A Mixed Selection Deletes Only The Settled Rows
//       Six rows, five marked plus a mark for a row that is gone. One marked
//       row is connected when the list paints it, one connects after it is
//       marked, and one refuses its removal. The two settled rows go, in list
//       order; the connected rows are reported as connected and left alone;
//       the refusal is reported with its error and its row stays; the
//       unmarked row is untouched. The progress counts every target.
//
//   B — A Settled Selection Deletes Whole And Skips Nothing
//       Twenty-three settled rows, all marked. Every row goes and nothing is
//       reported, the report the list answers with a toast. The confirmation
//       text lists the first twenty names and counts the rest, and the
//       progress climbs one by one to the last row.

#if DEBUG
import Foundation
import NetworkExtension

final class TunnelBulkDeleteWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Bulk Delete (List Selection)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("A Mixed Selection Deletes Only The Settled Rows", aMixedSelectionDeletesOnlyTheSettledRows),
            WorkflowStep("A Settled Selection Deletes Whole And Skips Nothing", aSettledSelectionDeletesWhole),
        ]
    }

    private struct Rig {
        let manager: TunnelsManager
        let vault: FaultVaultClient
        let providers: [String: FakeSlotProvider]
    }

    private let runTag = String(UUID().uuidString.prefix(8))

    private func name(_ label: String) -> String { "TE-Delete-\(label)-\(runTag)" }

    // MARK: - Rig

    private func rig(_ rows: [(name: String, status: NEVPNStatus)]) -> Rig? {
        let vault = FaultVaultClient()
        vault.readAllAnswer = .answers(.configs([]))
        vault.readAnswer = .answers(.unreachable)
        vault.storeAnswer = .answers(.done)
        vault.deleteAnswer = .answers(.done)
        var providers: [String: FakeSlotProvider] = [:]
        var ordered: [FakeSlotProvider] = []
        for row in rows {
            guard let config = TestConfigFactory.throwaway(name: row.name) else { return nil }
            vault.readAnswers[config.id] = .answers(.config(config))
            let provider = FakeSlotProvider(name: config.name, identity: config.identity, status: row.status)
            providers[row.name] = provider
            ordered.append(provider)
        }
        let manager = TunnelsManager(
            tunnelProviders: ordered,
            providerFactory: FakeSlotFactory(canned: ordered),
            vault: vault,
            observesSystemChanges: false
        )
        return Rig(manager: manager, vault: vault, providers: providers)
    }

    private func ordered(_ manager: TunnelsManager) -> [TunnelContainer] {
        TunnelListRules.ordered(manager.tunnels, saved: [], id: \.id)
    }

    // MARK: - Steps

    private func aMixedSelectionDeletesOnlyTheSettledRows() async {
        let gone = [name("Gone-1"), name("Gone-2")]
        let live = name("Live")
        let late = name("Late")
        let stuck = name("Stuck")
        let keep = name("Keep")
        guard let rig = rig([
            (gone[0], .disconnected), (live, .connected), (late, .disconnected),
            (stuck, .disconnected), (gone[1], .disconnected), (keep, .disconnected),
        ]) else {
            fail("the config factory did not produce the six throwaways this step needs")
            return
        }
        let rows = ordered(rig.manager)
        let settled = Set(rows.filter(\.isSettledInactive).map(\.name))
        guard rows.count == 6, settled == Set(gone + [late, stuck, keep]) else {
            fail("the side manager did not paint the rows this step needs (rows=\(rows.count), settled=\(settled.count))")
            return
        }

        let markedNames = Set(gone + [live, late, stuck])
        let marked = Set(rows.filter { markedNames.contains($0.name) }.map(\.id)).union([UUID()])
        let targets = TunnelBulkDelete.targets(rows, marked: marked)
        check(targets.map(\.name) == rows.map(\.name).filter { markedNames.contains($0) },
              "the targets are the marked rows in list order, the mark for a missing row dropped (targets=\(targets.count))")

        rig.providers[late]?.setStatusSilently(.connected)
        rig.providers[stuck]?.removeAnswer = .fails(NSError(
            domain: "TunnelBulkDeleteWorkflow", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "the fake entry refused its removal"]
        ))

        var progress: [Int] = []
        let report = await TunnelBulkDelete.run(targets, in: rig.manager) { progress.append($0) }
        log("deleted \(report.deleted); skipped \(report.skipped.map { "\($0.name): \($0.skip)" })")
        let listed = Set(rig.manager.tunnels.map(\.name))
        let deletedIds = Set(rig.vault.deletedIds)
        let id = { (row: String) in rows.first { $0.name == row }?.id }

        check(report.deleted == rows.map(\.name).filter { gone.contains($0) }
                && listed.isDisjoint(with: gone)
                && gone.allSatisfy { id($0).map(deletedIds.contains) ?? false },
              "the two settled rows went in list order, off the list and out of the vault (deleted=\(report.deleted))")

        let connected = report.skipped.filter { $0.skip == .connected }.map(\.name)
        let untouched = [live, late].allSatisfy { rig.providers[$0]?.removeCount == 0 && rig.providers[$0]?.stopCount == 0 }
        check(connected == rows.map(\.name).filter { [live, late].contains($0) }
                && untouched && listed.isSuperset(of: [live, late]),
              "the row painted connected and the row that connected after its mark were reported connected and left alone (connected=\(connected))")

        let refusal = report.skipped.first { $0.name == stuck }?.skip
        let refusedText: String? = { if case .failed(let text) = refusal { return text }; return nil }()
        check(refusedText.map { !$0.isEmpty } == true
                && listed.contains(stuck)
                && !(id(stuck).map(deletedIds.contains) ?? true),
              "the refused removal was reported with its error, its row and its payload stay (\(String(describing: refusal)))")

        check(listed.contains(keep) && rig.providers[keep]?.removeCount == 0,
              "the unmarked row was left alone")

        let loc = LocalizationManager.shared
        let lines = TunnelBulkDelete.message(report, loc: loc).components(separatedBy: "\n")
        let expectedLines = rows.map(\.name).compactMap { row -> String? in
            if row == live || row == late { return "\(row) — \(loc.t("delete_skip_connected"))" }
            if row == stuck { return refusedText.map { "\(row) — \($0)" } }
            return nil
        }
        check(report.total == targets.count
                && TunnelBulkDelete.title(report, loc: loc) == loc.t("delete_report_partial", gone.count, targets.count)
                && lines == expectedLines,
              "the report counts every target and names each skipped row with its reason, in list order (total=\(report.total), lines=\(lines.count))")

        check(progress == Array(1...targets.count),
              "the progress counted each target once, the skipped and the refused ones included (progress=\(progress))")
    }

    private func aSettledSelectionDeletesWhole() async {
        let names = (1...23).map { name(String(format: "Row-%02d", $0)) }
        guard let rig = rig(names.map { ($0, .disconnected) }) else {
            fail("the config factory did not produce the throwaways this step needs")
            return
        }
        let rows = ordered(rig.manager)
        guard rows.count == names.count, rows.allSatisfy(\.isSettledInactive) else {
            fail("the side manager did not paint \(names.count) settled rows (rows=\(rows.count))")
            return
        }
        let targets = TunnelBulkDelete.targets(rows, marked: Set(rows.map(\.id)))

        let loc = LocalizationManager.shared
        let confirm = TunnelBulkDelete.confirmMessage(targets.map(\.name), loc: loc).components(separatedBy: "\n")
        let shown = targets.prefix(TunnelBulkDelete.shownLines).map { "• \($0.name)" }
        check(confirm.count == TunnelBulkDelete.shownLines + 2
                && Array(confirm.dropFirst().prefix(TunnelBulkDelete.shownLines)) == shown
                && confirm.last == loc.t("import_report_more", targets.count - TunnelBulkDelete.shownLines),
              "the confirmation lists the first \(TunnelBulkDelete.shownLines) names in list order and counts the rest (lines=\(confirm.count))")

        var progress: [Int] = []
        let report = await TunnelBulkDelete.run(targets, in: rig.manager) { progress.append($0) }
        check(report.skipped.isEmpty && report.deleted == targets.map(\.name) && rig.manager.tunnels.isEmpty,
              "every row went and nothing was reported (deleted=\(report.deleted.count), skipped=\(report.skipped.count), left=\(rig.manager.tunnels.count))")
        check(progress == Array(1...targets.count),
              "the progress climbed one by one to \(targets.count) (last=\(progress.last ?? 0), calls=\(progress.count))")
    }
}
#endif
