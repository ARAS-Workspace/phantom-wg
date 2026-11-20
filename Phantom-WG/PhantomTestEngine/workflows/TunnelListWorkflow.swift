// Tunnel List
//
// The tunnel list's rules (package 5), checked apart from the list's views:
// which tunnel the top section shows, which names a search holds, and the
// order a drag leaves. Mac 2.2.1's `TunnelListRules` and
// `TunnelListOrderStore` are the source; Mac runs no engine family over
// them.
//
// A runs the rule over plain rows first, then over a `TunnelsManager` of
// the step's own whose rows are `FakeSlotProvider`s, as Activation Seam
// does. B runs the search rule over plain names and logs the run's
// locale. The rule folds under one fixed locale, and a run launched under a
// Turkish one (`-AppleLocale tr_TR -AppleLanguages (tr)`) answers the same.
// C and D run the order rules over plain ids, D beside SwiftUI's own move
// of an array; E writes the order into a defaults suite of the step's own
// and empties it. The suite has one name for every run: the system keeps a
// file for each suite it has made. The section, the search page and the
// drag on screen are tried by hand.
//
// Scenarios:
//
//   A — The Active Section Shows The Slot Holder
//       Over plain rows, a tunnel up, coming up or reasserting is shown
//       though one going down is listed above it, one going down is shown
//       before one queued in either order, and one coming up or reasserting
//       before one queued. Of two of equal rank the one listed first is
//       shown. A list at rest shows none. Over the manager, B, the newer
//       tunnel, is listed above A, and a tunnel whose configuration cannot
//       be read below the dated ones. B is pressed while A holds the slot:
//       while B waits and A goes down, the section shows A; once A's session
//       ends, it shows B.
//
//   B — Search Folds Case, Marks And The Turkish I
//       A query holds a name whatever its letter case and marks: "agi"
//       and "AĞI" find "Ev Ağı", "KILIC" finds "Kılıç", "istanbul"
//       finds "İstanbul" and "isik" finds "Işık". Spaces around a
//       query are passed over and a query of spaces alone holds every
//       name; a query the name does not hold finds nothing.
//
//   C — A Saved Order Keeps Its Rows And Puts New Ones First
//       Rows the saved order names follow it; rows it names not yet come
//       first, in the list's own order. An id saved for a tunnel the list
//       holds no longer is passed over, and an id saved twice places its
//       row once. With nothing saved the list keeps its order.
//
//   D — A Drag Lands Where It Drops
//       Rows dragged down, up, past the end and two at once land before the
//       row that stood at the drop, as SwiftUI's own move gives for each;
//       a drop on the row's own place changes nothing. One step up or down
//       swaps a row with its neighbour, and a row at the edge, or an id the
//       order does not hold, stays.
//
//   E — The Order Is Kept Across A Launch
//       An order saved into a defaults suite reads back the same and is
//       stored under `tunnel_list_order` as the ids' strings; a stored entry
//       that is not an id is passed over, and a suite that holds no order
//       reads back none.

#if DEBUG
import Foundation
import SwiftUI

final class TunnelListWorkflow: TestWorkflow {
    override var displayName: String { "Tunnel List (The Active Section, Search And Order)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("The Active Section Shows The Slot Holder", theActiveSectionShowsTheSlotHolder),
            WorkflowStep("Search Folds Case, Marks And The Turkish I", searchFoldsCaseMarksAndTheTurkishI),
            WorkflowStep("A Saved Order Keeps Its Rows And Puts New Ones First", aSavedOrderKeepsItsRowsAndPutsNewOnesFirst),
            WorkflowStep("A Drag Lands Where It Drops", aDragLandsWhereItDrops),
            WorkflowStep("The Order Is Kept Across A Launch", theOrderIsKeptAcrossALaunch)
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

    /// One plain row of steps C and D: a name and an id.
    private struct Named {
        let name: String
        let id = UUID()
    }

    /// One drag of step D: the offsets dragged, the drop and the names after.
    private struct DragCase {
        let offsets: IndexSet
        let destination: Int
        let after: [String]
    }

    /// One step of step D: the row, the direction and the names after.
    private struct StepCase {
        let row: String
        let up: Bool
        let after: [String]
    }

    /// Step A's plain rows, in list order, and the row the section shows.
    private let slotCases = [
        SlotCase(rows: [Row(name: "queued", status: .waiting), Row(name: "going down", status: .deactivating)],
                 shows: "going down"),
        SlotCase(rows: [Row(name: "going down", status: .deactivating), Row(name: "queued", status: .waiting)],
                 shows: "going down"),
        SlotCase(rows: [Row(name: "queued", status: .waiting), Row(name: "coming up", status: .activating)],
                 shows: "coming up"),
        SlotCase(rows: [Row(name: "at rest", status: .inactive), Row(name: "reasserting", status: .reasserting),
                        Row(name: "queued", status: .waiting)],
                 shows: "reasserting"),
        SlotCase(rows: [Row(name: "going down", status: .deactivating), Row(name: "up", status: .active)],
                 shows: "up"),
        SlotCase(rows: [Row(name: "going down", status: .deactivating), Row(name: "coming up", status: .activating)],
                 shows: "coming up"),
        SlotCase(rows: [Row(name: "going down", status: .deactivating), Row(name: "reasserting", status: .reasserting)],
                 shows: "reasserting"),
        SlotCase(rows: [Row(name: "reasserting", status: .reasserting), Row(name: "coming up", status: .activating)],
                 shows: "reasserting"),
        SlotCase(rows: [Row(name: "coming up", status: .activating), Row(name: "reasserting", status: .reasserting)],
                 shows: "coming up"),
        SlotCase(rows: [Row(name: "at rest A", status: .inactive), Row(name: "at rest B", status: .inactive)],
                 shows: nil)
    ]

    // MARK: - Steps

    func theActiveSectionShowsTheSlotHolder() async {
        for entry in slotCases {
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
        let unread = TunnelContainer(tunnel: FakeSlotProvider(config: nil))
        let listed = TunnelsManager.sortedByCreatedAt([unread, rowA, rowB])
        check(listed.first === rowB && listed.last === unread,
              "a tunnel whose configuration cannot be read is listed below the dated ones"
              + " (order=\(listed.map { $0 === unread ? "unread" : $0.name }))")

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

    func aSavedOrderKeepsItsRowsAndPutsNewOnesFirst() async {
        let rows = ["new 2", "new 1", "a", "b", "c"].map { Named(name: $0) }
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.id) })
        let names: ([UUID]) -> [String] = { saved in
            TunnelListRules.ordered(rows, saved: saved, id: \.id).map(\.name)
        }
        let gone = UUID()
        let saved = ["c", "gone", "a", "c", "b"].map { byName[$0] ?? gone }
        let mixed = names(saved)
        check(mixed == ["new 2", "new 1", "c", "a", "b"],
              "saved c, a, b with a gone id and c twice: the new rows first, then c, a, b once each (rows=\(mixed))")
        let unsaved = names([])
        check(unsaved == ["new 2", "new 1", "a", "b", "c"],
              "with nothing saved the list keeps its own order (rows=\(unsaved))")
        let whole = names(["b", "new 1", "c", "a", "new 2"].compactMap { byName[$0] })
        check(whole == ["b", "new 1", "c", "a", "new 2"],
              "an order naming every row is followed as it is (rows=\(whole))")
    }

    func aDragLandsWhereItDrops() async {
        let rows = ["a", "b", "c", "d"].map { Named(name: $0) }
        let ids = rows.map(\.id)
        let name: (UUID) -> String = { id in rows.first { $0.id == id }?.name ?? "?" }
        let drags = [
            DragCase(offsets: [0], destination: 3, after: ["b", "c", "a", "d"]),
            DragCase(offsets: [3], destination: 0, after: ["d", "a", "b", "c"]),
            DragCase(offsets: [1], destination: 4, after: ["a", "c", "d", "b"]),
            DragCase(offsets: [0, 2], destination: 4, after: ["b", "d", "a", "c"]),
            DragCase(offsets: [2], destination: 2, after: ["a", "b", "c", "d"]),
            DragCase(offsets: [2], destination: 3, after: ["a", "b", "c", "d"])
        ]
        for drag in drags {
            let landed = TunnelListRules.moved(ids, from: drag.offsets, to: drag.destination).map(name)
            var swiftUI = ids
            swiftUI.move(fromOffsets: drag.offsets, toOffset: drag.destination)
            let dragged = drag.offsets.map { rows[$0].name }
            check(landed == drag.after && landed == swiftUI.map(name),
                  "\(dragged) dropped at \(drag.destination) gives \(drag.after), as SwiftUI's move does"
                  + " (rows=\(landed), swiftUI=\(swiftUI.map(name)))")
        }
        let steps = [
            StepCase(row: "b", up: true, after: ["b", "a", "c", "d"]),
            StepCase(row: "c", up: false, after: ["a", "b", "d", "c"]),
            StepCase(row: "a", up: true, after: ["a", "b", "c", "d"]),
            StepCase(row: "d", up: false, after: ["a", "b", "c", "d"])
        ]
        for step in steps {
            guard let id = rows.first(where: { $0.name == step.row })?.id else { continue }
            let stepped = TunnelListRules.movedByOne(ids, id, up: step.up).map(name)
            check(stepped == step.after,
                  "one step \(step.up ? "up" : "down") for \(step.row) gives \(step.after) (rows=\(stepped))")
        }
        let stranger = TunnelListRules.movedByOne(ids, UUID(), up: true).map(name)
        check(stranger == ["a", "b", "c", "d"], "a step for an id the order does not hold changes nothing (rows=\(stranger))")
    }

    func theOrderIsKeptAcrossALaunch() async {
        // One name for every run: the system keeps a file for each suite it has made.
        let suite = "TE-List-Order"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("the defaults suite \(suite) could not be opened")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        onTeardown("empty the step's defaults suite") { defaults.removePersistentDomain(forName: suite) }
        let atFirst = TunnelListOrderStore.load(from: defaults)
        check(atFirst.isEmpty, "a suite that holds no order reads back none (ids=\(atFirst.count))")
        let order = [UUID(), UUID(), UUID()]
        TunnelListOrderStore.save(order, to: defaults)
        let back = TunnelListOrderStore.load(from: defaults)
        check(back == order, "the saved order reads back the same (\(back.count) of \(order.count) ids, same order=\(back == order))")
        let stored = defaults.stringArray(forKey: "tunnel_list_order")
        check(stored == order.map(\.uuidString),
              "the order is stored under tunnel_list_order as the ids' strings"
              + " (stored=\(stored?.count ?? 0) of \(order.count), as written=\(stored == order.map(\.uuidString)))")
        defaults.set(["not an id", order[1].uuidString], forKey: TunnelListOrderStore.key)
        let filtered = TunnelListOrderStore.load(from: defaults)
        check(filtered == [order[1]], "a stored entry that is not an id is passed over (ids=\(filtered.count))")
    }
}
#endif
