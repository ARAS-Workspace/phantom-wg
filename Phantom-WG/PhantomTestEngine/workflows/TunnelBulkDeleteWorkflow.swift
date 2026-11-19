// Tunnel Bulk Delete
//
// The list's deletes, driven through `TunnelBulkDelete` the way the list
// drives them, without the swipe, the confirmation and the owner prompt
// around them. Mac 2.2.1's Tunnel Bulk Delete A and B are the source; C is
// iOS's.
//
// A and B run over a `TunnelsManager` of the step's own whose rows are
// `FakeSlotProvider`s, as Activation Seam does; C reads containers over
// fakes alone. iOS has no vault: a removal is read off the list and the
// fake's removal count, and a refused one by its row and its configuration
// still there. The swipe and the selection on screen are tried by hand.
//
// Scenarios:
//
//   A — A Mixed Selection Deletes Only The Settled Rows
//       Six rows, five marked plus a mark for a row that is gone. One marked
//       row is connected when the list paints it, one connects after it is
//       marked, and one refuses its removal. The two settled rows go, in
//       list order; the connected rows are reported as connected and left
//       alone; the refusal is reported with its error and its row stays; the
//       unmarked row is untouched. The progress counts every target.
//
//   B — A Settled Selection Deletes Whole And Skips Nothing
//       Twenty-three settled rows, all marked. Every row goes and nothing is
//       reported. The confirmation text lists the first twenty names and
//       counts the rest, and the progress climbs one by one to the last row.
//
//   C — The Gate Reads The System, The Row And The Attempt
//       A row the system reads disconnected, or invalid as an entry saved
//       disabled reads, and that is painted at rest is let go. A row whose
//       session is coming up or going down while it is painted at rest, a
//       row painted queued, and a row with an activation attempt under way
//       are held.

#if DEBUG
import Foundation
import NetworkExtension

final class TunnelBulkDeleteWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel Bulk Delete (List Deletes)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("A Mixed Selection Deletes Only The Settled Rows", aMixedSelectionDeletesOnlyTheSettledRows),
            WorkflowStep("A Settled Selection Deletes Whole And Skips Nothing", aSettledSelectionDeletesWhole),
            WorkflowStep("The Gate Reads The System, The Row And The Attempt", theGateReadsTheSystemTheRowAndTheAttempt)
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))

    private func name(_ label: String) -> String { "TE-Delete-\(label)-\(runTag)" }

    /// One row a rig opens: a name and the status the fake system reads.
    private struct Row {
        let name: String
        let status: NEVPNStatus
    }

    private struct Rig {
        let manager: TunnelsManager
        let providers: [String: FakeSlotProvider]
    }

    /// Step A's six rows: two settled to go, one connected, one that
    /// connects after its mark, one that refuses its removal, one unmarked.
    private struct Mixed {
        let gone: [String]
        let live: String
        let late: String
        let stuck: String
        let keep: String

        var rows: [Row] {
            [Row(name: gone[0], status: .disconnected), Row(name: live, status: .connected),
             Row(name: late, status: .disconnected), Row(name: stuck, status: .disconnected),
             Row(name: gone[1], status: .disconnected), Row(name: keep, status: .disconnected)]
        }
    }

    /// One case of step C: what is set on a container and whether the gate
    /// lets it go.
    private struct GateCase {
        let label: String
        let lets: Bool
        let arrange: (TunnelContainer, FakeSlotProvider) -> Void
    }

    // MARK: - Rig

    private func rig(_ rows: [Row]) -> Rig? {
        var providers: [String: FakeSlotProvider] = [:]
        var ordered: [FakeSlotProvider] = []
        for row in rows {
            guard let config = TestConfigFactory.throwaway(name: row.name) else { return nil }
            let provider = FakeSlotProvider(config: config, status: row.status)
            providers[row.name] = provider
            ordered.append(provider)
        }
        let manager = TunnelsManager(tunnelProviders: ordered, providerFactory: FakeSlotFactory(canned: ordered))
        return Rig(manager: manager, providers: providers)
    }

    // MARK: - Steps

    func aMixedSelectionDeletesOnlyTheSettledRows() async {
        let mixed = Mixed(gone: [name("Gone-1"), name("Gone-2")], live: name("Live"), late: name("Late"),
                          stuck: name("Stuck"), keep: name("Keep"))
        guard let rig = rig(mixed.rows) else {
            fail("the config factory did not produce the six throwaways this step needs")
            return
        }
        let rows = rig.manager.tunnels
        let settled = Set(rows.filter(\.isSettledInactive).map(\.name))
        guard rows.count == 6, settled == Set(mixed.gone + [mixed.late, mixed.stuck, mixed.keep]) else {
            fail("the step's manager did not paint the rows this step needs (rows=\(rows.count), settled=\(settled.count))")
            return
        }

        let markedNames = Set(mixed.gone + [mixed.live, mixed.late, mixed.stuck])
        let marked = Set(rows.filter { markedNames.contains($0.name) }.map(\.id)).union([UUID()])
        let targets = TunnelBulkDelete.targets(rows, marked: marked)
        check(targets.map(\.name) == rows.map(\.name).filter { markedNames.contains($0) },
              "the targets are the marked rows in list order, the mark for a missing row dropped (targets=\(targets.count))")

        rig.providers[mixed.late]?.setStatusSilently(.connected)
        rig.providers[mixed.stuck]?.removeAnswer = .fails(NSError(
            domain: "TE.Fake", code: 6, userInfo: [NSLocalizedDescriptionKey: "test rig refused the removal"]
        ))

        var progress: [Int] = []
        let report = await TunnelBulkDelete.run(targets, in: rig.manager) { progress.append($0) }
        log("deleted \(report.deleted); skipped \(report.skipped.map { "\($0.name): \($0.skip)" })")
        let listed = Set(rig.manager.tunnels.map(\.name))

        check(report.deleted == rows.map(\.name).filter { mixed.gone.contains($0) }
                && listed.isDisjoint(with: mixed.gone)
                && mixed.gone.allSatisfy { rig.providers[$0]?.removeCount == 1 },
              "the two settled rows went in list order, off the list and out of the system's entries (deleted=\(report.deleted))")

        let held = [mixed.live, mixed.late]
        let connected = report.skipped.filter { $0.skip == .connected }.map(\.name)
        let untouched = held.allSatisfy { rig.providers[$0]?.removeCount == 0 && rig.providers[$0]?.stopCount == 0 }
        check(connected == rows.map(\.name).filter { held.contains($0) } && untouched && listed.isSuperset(of: held),
              "the row painted connected and the row that connected after its mark were reported connected and left alone"
              + " (connected=\(connected))")

        let refusal = report.skipped.first { $0.name == mixed.stuck }?.skip
        let refusedText: String? = { if case .failed(let text) = refusal { return text }; return nil }()
        let stuckRow = rig.manager.tunnels.first { $0.name == mixed.stuck }
        check(refusedText.map { !$0.isEmpty } == true && stuckRow?.tunnelConfig != nil,
              "the refused removal was reported with its error, its row and its configuration stay (\(String(describing: refusal)))")

        check(listed.contains(mixed.keep) && rig.providers[mixed.keep]?.removeCount == 0,
              "the unmarked row was left alone")
        checkReportText(report, rows: rows, targets: targets.count, mixed: mixed, refusedText: refusedText)
        check(progress == Array(1...targets.count),
              "the progress counted each target once, the skipped and the refused ones included (progress=\(progress))")
    }

    /// Step A's report as the list words it: the count of every target and
    /// one line per skipped row, in list order.
    private func checkReportText(_ report: TunnelBulkDelete.Report, rows: [TunnelContainer], targets: Int,
                                 mixed: Mixed, refusedText: String?) {
        let loc = LocalizationManager.shared
        let lines = TunnelBulkDelete.message(report, loc: loc).components(separatedBy: "\n")
        let expectedLines = rows.map(\.name).compactMap { row -> String? in
            if row == mixed.live || row == mixed.late { return "\(row) — \(loc.t("delete_skip_connected"))" }
            if row == mixed.stuck { return refusedText.map { "\(row) — \($0)" } }
            return nil
        }
        check(report.total == targets
                && TunnelBulkDelete.title(report, loc: loc) == loc.t("delete_report_partial", mixed.gone.count, targets)
                && lines == expectedLines,
              "the report counts every target and names each skipped row with its reason, in list order"
              + " (total=\(report.total), lines=\(lines.count))")
    }

    func aSettledSelectionDeletesWhole() async {
        let names = (1...23).map { name(String(format: "Row-%02d", $0)) }
        guard let rig = rig(names.map { Row(name: $0, status: .disconnected) }) else {
            fail("the config factory did not produce the throwaways this step needs")
            return
        }
        let rows = rig.manager.tunnels
        guard rows.count == names.count, rows.allSatisfy(\.isSettledInactive) else {
            fail("the step's manager did not paint \(names.count) settled rows (rows=\(rows.count))")
            return
        }
        let targets = TunnelBulkDelete.targets(rows, marked: Set(rows.map(\.id)))

        let loc = LocalizationManager.shared
        let shownLines = TunnelBulkExport.shownLines
        let confirm = TunnelBulkDelete.confirmMessage(targets.map(\.name), loc: loc).components(separatedBy: "\n")
        let shown = targets.prefix(shownLines).map { "• \($0.name)" }
        check(confirm.count == shownLines + 2
                && Array(confirm.dropFirst().prefix(shownLines)) == shown
                && confirm.last == loc.t("import_report_more", targets.count - shownLines),
              "the confirmation lists the first \(shownLines) names in list order and counts the rest (lines=\(confirm.count))")

        var progress: [Int] = []
        let report = await TunnelBulkDelete.run(targets, in: rig.manager) { progress.append($0) }
        check(report.skipped.isEmpty && report.deleted == targets.map(\.name) && rig.manager.tunnels.isEmpty,
              "every row went and nothing was reported"
              + " (deleted=\(report.deleted.count), skipped=\(report.skipped.count), left=\(rig.manager.tunnels.count))")
        check(progress == Array(1...targets.count),
              "the progress climbed one by one to \(targets.count) (last=\(progress.last ?? 0), calls=\(progress.count))")
    }

    func theGateReadsTheSystemTheRowAndTheAttempt() async {
        let cases = [
            GateCase(label: "disconnected and painted at rest", lets: true) { _, _ in },
            GateCase(label: "invalid, as a disabled entry reads, and painted at rest", lets: true) { row, fake in
                fake.setStatusSilently(.invalid)
                row.status = .inactive
            },
            GateCase(label: "coming up while painted at rest", lets: false) { _, fake in fake.setStatusSilently(.connecting) },
            GateCase(label: "going down while painted at rest", lets: false) { _, fake in fake.setStatusSilently(.disconnecting) },
            GateCase(label: "painted queued", lets: false) { row, _ in row.status = .waiting },
            GateCase(label: "with an activation attempt under way", lets: false) { row, _ in row.isAttemptingActivation = true }
        ]
        for entry in cases {
            guard let config = TestConfigFactory.throwaway(name: name("Gate")) else {
                fail("the config factory produced no throwaway")
                return
            }
            let fake = FakeSlotProvider(config: config, status: .disconnected)
            let row = TunnelContainer(tunnel: fake)
            entry.arrange(row, fake)
            check(row.isSettledInactive == entry.lets,
                  "a row \(entry.label) is \(entry.lets ? "let go" : "held") (status=\(row.status), live=\(fake.connectionStatus.rawValue))")
        }
    }
}
#endif
