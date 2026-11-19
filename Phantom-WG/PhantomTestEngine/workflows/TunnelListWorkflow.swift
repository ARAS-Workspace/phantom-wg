// Tunnel List
//
// The tunnel list's rules (package 5), checked apart from the list's views:
// which tunnel the top section shows and which names a search holds. Mac
// 2.2.1's `TunnelListRules` is the source; Mac runs no engine family over
// them.
//
// A runs the rule over plain rows first, then over a `TunnelsManager` of
// the step's own whose rows are `FakeSlotProvider`s, as Activation Seam
// does. B runs the search rule over plain names and logs the run's
// locale. The rule folds under one fixed locale, and a run launched under a
// Turkish one (`-AppleLocale tr_TR -AppleLanguages (tr)`) answers the same.
// The section and the search field on screen are tried by hand.
//
// Scenarios:
//
//   A — The Active Section Shows The Slot Holder
//       Over plain rows in either order, a tunnel up, coming up or
//       reasserting is shown before one going down, and one going down
//       before one queued; a list at rest shows none. Over the manager, B,
//       listed above A, is pressed while A holds the slot: while B waits
//       and A goes down, the section shows A; once A's session ends, it
//       shows B.
//
//   B — Search Folds Case, Marks And The Turkish I
//       A query holds a name whatever its letter case and marks: "agi"
//       and "AĞI" find "Ev Ağı", "KILIC" finds "Kılıç", "istanbul"
//       finds "İstanbul" and "isik" finds "Işık". Spaces around a
//       query are passed over and a query of spaces alone holds every
//       name; a query the name does not hold finds nothing.

#if DEBUG
import Foundation

final class TunnelListWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel List (The Active Section And Search)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("The Active Section Shows The Slot Holder", theActiveSectionShowsTheSlotHolder),
            WorkflowStep("Search Folds Case, Marks And The Turkish I", searchFoldsCaseMarksAndTheTurkishI)
        ]
    }

    let runTag = String(UUID().uuidString.prefix(8))

    /// One plain row: a name and the status it is painted with.
    private struct Row {
        let name: String
        let status: TunnelStatus
    }

    /// One case of step A: rows in list order and the row the section shows.
    private struct SlotCase {
        let rows: [Row]
        let shows: String?
    }

    /// One case of step B: a name, a query and whether the name holds it.
    private struct SearchCase {
        let name: String
        let query: String
        let holds: Bool
    }

    // MARK: - Steps

    func theActiveSectionShowsTheSlotHolder() async {
        let cases = [
            SlotCase(rows: [Row(name: "queued", status: .waiting), Row(name: "going down", status: .deactivating)],
                     shows: "going down"),
            SlotCase(rows: [Row(name: "going down", status: .deactivating), Row(name: "queued", status: .waiting)],
                     shows: "going down"),
            SlotCase(rows: [Row(name: "queued", status: .waiting), Row(name: "coming up", status: .activating)],
                     shows: "coming up"),
            SlotCase(rows: [Row(name: "at rest", status: .inactive), Row(name: "reasserting", status: .reasserting),
                            Row(name: "queued", status: .waiting)],
                     shows: "reasserting"),
            SlotCase(rows: [Row(name: "at rest A", status: .inactive), Row(name: "at rest B", status: .inactive)],
                     shows: nil)
        ]
        for entry in cases {
            let shown = TunnelListRules.slotHolder(in: entry.rows) { $0.status }?.name
            check(shown == entry.shows,
                  "over \(entry.rows.map { "\($0.name) \($0.status)" }) the section shows \(entry.shows ?? "none")"
                  + " (shown=\(shown ?? "none"))")
        }

        guard var configA = TestConfigFactory.throwaway(name: "TE-List-Slot-A-\(runTag)"),
              var configB = TestConfigFactory.throwaway(name: "TE-List-Slot-B-\(runTag)") else {
            fail("the config factory did not produce the two throwaways this step needs")
            return
        }
        configA.createdAt = Date(timeIntervalSinceNow: -60)
        configB.createdAt = Date()
        let fakeA = FakeSlotProvider(config: configA, status: .connected)
        fakeA.isEnabled = true
        let fakeB = FakeSlotProvider(config: configB, status: .disconnected)
        let manager = TunnelsManager(tunnelProviders: [fakeA, fakeB], providerFactory: FakeSlotFactory(canned: [fakeA, fakeB]))
        guard let rowA = manager.tunnels.first(where: { $0.id == configA.id }),
              let rowB = manager.tunnels.first(where: { $0.id == configB.id }) else {
            fail("the manager did not list the two rows")
            return
        }
        guard check(manager.tunnels.first === rowB && rowA.status == .active,
                    "B, the newer tunnel, is listed above A, and A holds the slot"
                    + " (order=\(manager.tunnels.map(\.name)), A=\(rowA.status))") else { return }

        manager.startActivation(of: rowB)
        guard check(rowB.status == .waiting && rowA.status == .deactivating,
                    "the press on B queues B and stops A (B=\(rowB.status), A=\(rowA.status))") else { return }
        let during = TunnelListRules.slotHolder(in: manager.tunnels, status: \.status)
        check(during === rowA,
              "while B waits and A goes down, the section shows A (shows=\(during?.name ?? "none"))")

        fakeA.drive(.disconnected)
        let handedOn = await settle(within: 3) { fakeB.startCount >= 1 }
        let after = TunnelListRules.slotHolder(in: manager.tunnels, status: \.status)
        check(handedOn && after === rowB,
              "once A's session ends, the section shows B (starts=\(fakeB.startCount), shows=\(after?.name ?? "none"))")
    }

    func searchFoldsCaseMarksAndTheTurkishI() async {
        log("this run's locale is \(Locale.current.identifier)")
        let cases = [
            SearchCase(name: "Ev Ağı", query: "ev", holds: true),
            SearchCase(name: "Ev Ağı", query: "agi", holds: true),
            SearchCase(name: "Ev Ağı", query: "AĞI", holds: true),
            SearchCase(name: "Kılıç", query: "kilic", holds: true),
            SearchCase(name: "Kılıç", query: "KILIÇ", holds: true),
            SearchCase(name: "Kılıç", query: "KILIC", holds: true),
            SearchCase(name: "İstanbul", query: "istanbul", holds: true),
            SearchCase(name: "İstanbul", query: "ıstanbul", holds: true),
            SearchCase(name: "İstanbul", query: "ISTANBUL", holds: true),
            SearchCase(name: "Işık", query: "isik", holds: true),
            SearchCase(name: "Işık", query: "IŞIK", holds: true),
            SearchCase(name: "Işık", query: "ışık", holds: true),
            SearchCase(name: "Şube Öğle", query: "sube ogle", holds: true),
            SearchCase(name: "Home", query: "HOME", holds: true),
            SearchCase(name: "Home", query: " ho ", holds: true),
            SearchCase(name: "Home", query: "   ", holds: true),
            SearchCase(name: "Home", query: "zz", holds: false),
            SearchCase(name: "Ev Ağı", query: "Ağ Kuzey", holds: false)
        ]
        for entry in cases {
            let held = TunnelListRules.matches(entry.name, query: entry.query)
            check(held == entry.holds,
                  "\"\(entry.name)\" \(entry.holds ? "holds" : "does not hold") the query \"\(entry.query)\" (held=\(held))")
        }
    }
}
#endif
