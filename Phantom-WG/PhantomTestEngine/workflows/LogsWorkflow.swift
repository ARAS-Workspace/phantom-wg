// Logs
//
// `LogStore`, the reader behind the log screen and the detail badge,
// driven against a fake extension: its buffer is `logLines`, opcode 1
// answers the lines, opcode 4 their count, opcode 2 empties the buffer.
// `messageOpcodes` is what the store sent, which is how a step reads which
// question the store asked. The store polls every 0.5 s.
//
// Each step runs one store over one row of a `TunnelsManager` of its own,
// so status changes driven on the fake reach the row as they would in the
// app.
//
// Scenarios:
//
//   A — The Badge Alone Asks The Count, Not The Lines
//       With only the badge holding the store, it sends opcode 4 and no
//       opcode 1, and its count is the buffer's. When the session ends,
//       the count is 0.
//
//   B — The Log Screen Reads The Lines At Once And Keeps Reading
//       The log screen's hold reads the lines before the first tick, and
//       a line the buffer gains reaches the rows and the count.
//
//   C — A Push And Pop In Either Order Keep The Store Reading
//       The badge holds, the log screen holds, the badge lets go: the
//       store reads lines on its ticks, not only at the hold. The badge
//       holds before the log screen lets go:
//       it reads the count. Both let go: nothing more is sent. A hold
//       taken after that starts the reading again.
//
//   D — An Extension That Leaves Opcode 4 Unanswered Is Read Through Opcode 1
//       With the count unanswered, the badge's count comes from the lines,
//       and the store asks opcode 1 from then on.
//
//   E — The Fallback Ends With The Session
//       After D's fallback, the session ends: the count is 0. When a
//       session comes back, the store asks opcode 4 again.
//
//   F — A Reasserting Session Keeps Its Lines
//       While the row reasserts, the rows stay and reading goes on; when
//       the session ends, the rows and the count are cleared and nothing
//       more is sent.
//       A session that is coming up is read again.
//
//   G — A Silent Extension Ends Each Wait At Five Seconds
//       Opcode 1 is never answered: short of five seconds nothing more is
//       asked; past it the store sends again (its loop is not frozen) and
//       shows no rows; once the log screen lets go, nothing more is
//       sent.
//
//   H — A Clear Empties The Buffer And The Rows
//       Clear sends opcode 2 and empties the rows and the count; a line
//       logged after it arrives under an id newer than any before.
//
//   I — Rows Keep Their Ids While The Buffer Slides
//       When the buffer drops its first line and gains a new one, the
//       lines still present keep their ids and the new one gets a new id.
//       The buffer's first two lines are one line twice: the rows are
//       matched past the first match.
//
//   J — An Answer That Says Nothing Or Does Not Decode Keeps The Rows
//       With rows on screen, an opcode 1 answered with nothing, and then
//       with bytes that do not decode, leaves the rows and the count as
//       they were while the store goes on asking.

#if DEBUG
import Foundation
import NetworkExtension

final class LogsWorkflow: TestWorkflow {
    override var displayName: String { "Logs (The Store Behind The Log Screen And The Badge)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("The Badge Alone Asks The Count, Not The Lines", theBadgeAloneAsksTheCountNotTheLines),
            WorkflowStep("The Log Screen Reads The Lines At Once And Keeps Reading", theLogScreenReadsTheLinesAtOnceAndKeepsReading),
            WorkflowStep("A Push And Pop In Either Order Keep The Store Reading", aPushAndPopInEitherOrderKeepTheStoreReading),
            WorkflowStep("An Extension That Leaves Opcode 4 Unanswered Is Read Through Opcode 1",
                         anExtensionThatLeavesOpcode4UnansweredIsReadThroughOpcode1),
            WorkflowStep("The Fallback Ends With The Session", theFallbackEndsWithTheSession),
            WorkflowStep("A Reasserting Session Keeps Its Lines", aReassertingSessionKeepsItsLines),
            WorkflowStep("A Silent Extension Ends Each Wait At Five Seconds", aSilentExtensionEndsEachWaitAtFiveSeconds),
            WorkflowStep("A Clear Empties The Buffer And The Rows", aClearEmptiesTheBufferAndTheRows),
            WorkflowStep("Rows Keep Their Ids While The Buffer Slides", rowsKeepTheirIdsWhileTheBufferSlides),
            WorkflowStep("An Answer That Says Nothing Or Does Not Decode Keeps The Rows",
                         anAnswerThatSaysNothingOrDoesNotDecodeKeepsTheRows)
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))

    // MARK: - Rig

    private struct Rig {
        let manager: TunnelsManager
        let fake: FakeSlotProvider
        let row: TunnelContainer
        let store: LogStore
    }

    /// One connected row whose buffer holds `lines` lines, and a store over it.
    private func rig(_ label: String, lines: Int = 3) -> Rig? {
        guard let config = TestConfigFactory.throwaway(name: "TE-Logs-\(label)-\(runTag)") else { return nil }
        let fake = FakeSlotProvider(config: config, status: .connected)
        fake.isEnabled = true
        fake.logLines = (1...max(lines, 1)).prefix(lines).map(line)
        let manager = TunnelsManager(tunnelProviders: [fake], providerFactory: FakeSlotFactory(canned: [fake]))
        guard let row = manager.tunnels.first else { return nil }
        return Rig(manager: manager, fake: fake, row: row, store: LogStore(tunnel: row))
    }

    private func line(_ index: Int) -> FakeSlotProvider.LogLine {
        FakeSlotProvider.LogLine(timestamp: "00:00:\(String(format: "%02d", index))", tag: "TE", message: "line \(index)")
    }

    /// The opcodes the store sent since `mark`.
    private func sent(_ fake: FakeSlotProvider, since mark: Int) -> [UInt8] {
        Array(fake.messageOpcodes.dropFirst(mark))
    }

    private func release(_ store: LogStore) {
        store.stopPolling()
        store.stopCounting()
    }

    // MARK: - Steps

    func theBadgeAloneAsksTheCountNotTheLines() async {
        guard let rig = rig("Badge") else {
            fail("the rig did not materialize its row")
            return
        }
        let (fake, store) = (rig.fake, rig.store)
        defer { release(store) }

        store.startCounting()
        let counted = await settle(within: 2) { store.count == 3 }
        let opcodes = sent(fake, since: 0)
        check(counted && opcodes.contains(4) && !opcodes.contains(1),
              "with only the badge holding, the store asks opcode 4 and no opcode 1, and counts the buffer"
              + " (count=\(store.count), sent=\(opcodes))")
        check(store.entries.isEmpty, "and it reads no rows (rows=\(store.entries.count))")

        fake.drive(.disconnected)
        let ended = await settle(within: 2) { store.count == 0 }
        check(ended, "when the session ends, the badge's count is 0 (count=\(store.count))")
    }

    func theLogScreenReadsTheLinesAtOnceAndKeepsReading() async {
        guard let rig = rig("Screen") else {
            fail("the rig did not materialize its row")
            return
        }
        let (fake, store) = (rig.fake, rig.store)
        defer { release(store) }

        store.startPolling()
        let atOnce = await settle(within: 0.3) { store.entries.count == 3 }
        check(atOnce, "the log screen's hold reads the lines before the first tick (rows=\(store.entries.count))")
        fake.logLines.append(line(4))
        let followed = await settle(within: 1.5) { store.entries.count == 4 && store.count == 4 }
        check(followed, "a line the buffer gains reaches the rows and the count (rows=\(store.entries.count), count=\(store.count))")
    }

    func aPushAndPopInEitherOrderKeepTheStoreReading() async {
        guard let rig = rig("Holds") else {
            fail("the rig did not materialize its row")
            return
        }
        let (fake, store) = (rig.fake, rig.store)
        defer { release(store) }

        store.startCounting()
        store.startPolling()
        store.stopCounting()
        try? await Task.sleep(for: .seconds(0.2))
        var mark = fake.messageOpcodes.count
        try? await Task.sleep(for: .seconds(1.2))
        let pushed = sent(fake, since: mark)
        check(pushed.contains(1), "with the badge let go after the log screen held, the store reads lines (sent=\(pushed))")

        store.startCounting()
        store.stopPolling()
        mark = fake.messageOpcodes.count
        try? await Task.sleep(for: .seconds(1.2))
        let popped = sent(fake, since: mark)
        check(popped.contains(4) && !popped.contains(1),
              "with the badge holding before the log screen let go, the store reads the count (sent=\(popped))")

        store.stopCounting()
        try? await Task.sleep(for: .seconds(0.6))
        mark = fake.messageOpcodes.count
        try? await Task.sleep(for: .seconds(1.2))
        let released = sent(fake, since: mark)
        check(released.isEmpty, "with both let go, nothing more is sent (sent=\(released))")

        mark = fake.messageOpcodes.count
        store.startCounting()
        let again = await settle(within: 1.5) { sent(fake, since: mark).contains(4) }
        check(again, "a hold taken after both let go starts the reading again (sent=\(sent(fake, since: mark)))")
    }

    func anExtensionThatLeavesOpcode4UnansweredIsReadThroughOpcode1() async {
        guard let rig = rig("Fallback") else {
            fail("the rig did not materialize its row")
            return
        }
        let (fake, store) = (rig.fake, rig.store)
        defer { release(store) }
        fake.countReply = .nothing

        store.startCounting()
        let counted = await settle(within: 2) { store.count == 3 }
        check(counted && fake.messageOpcodes.contains(4) && fake.messageOpcodes.contains(1),
              "with opcode 4 unanswered, the badge's count comes from the lines (count=\(store.count), sent=\(fake.messageOpcodes))")
        let mark = fake.messageOpcodes.count
        try? await Task.sleep(for: .seconds(1.2))
        let after = sent(fake, since: mark)
        check(!after.isEmpty && after.allSatisfy { $0 == 1 }, "and the store asks opcode 1 from then on (sent=\(after))")
    }

    func theFallbackEndsWithTheSession() async {
        guard let rig = rig("Session") else {
            fail("the rig did not materialize its row")
            return
        }
        let (fake, row, store) = (rig.fake, rig.row, rig.store)
        defer { release(store) }
        fake.countReply = .nothing

        store.startCounting()
        let arranged = await settle(within: 2, until: { store.count == 3 && fake.messageOpcodes.contains(1) })
        guard check(arranged, "the fallback is in place: the count comes from the lines"
                    + " (count=\(store.count), sent=\(fake.messageOpcodes))") else { return }
        fake.drive(.disconnected)
        let ended = await settle(within: 2) { row.status == .inactive && store.count == 0 }
        check(ended, "when the session ends, the count is 0 (status=\(row.status), count=\(store.count))")

        fake.countReply = .count
        fake.drive(.connected)
        guard await settle(within: 2, until: { row.status == .active }) else {
            fail("the row never came back active (status=\(row.status))")
            return
        }
        let mark = fake.messageOpcodes.count
        try? await Task.sleep(for: .seconds(1.2))
        let after = sent(fake, since: mark)
        check(after.contains(4) && !after.contains(1),
              "when a session comes back, the store asks opcode 4 again (sent=\(after), count=\(store.count))")
    }

    func aReassertingSessionKeepsItsLines() async {
        guard let rig = rig("Reassert") else {
            fail("the rig did not materialize its row")
            return
        }
        let (fake, row, store) = (rig.fake, rig.row, rig.store)
        defer { release(store) }

        store.startPolling()
        let read = await settle(within: 1, until: { store.entries.count == 3 })
        guard check(read, "the log screen reads the lines (rows=\(store.entries.count))") else { return }
        fake.drive(.reasserting)
        let reasserted = await settle(within: 1, until: { row.status == .reasserting })
        guard check(reasserted, "the row reasserts with its session (status=\(row.status))") else { return }
        let mark = fake.messageOpcodes.count
        let kept = await holds(for: 1.2) { store.entries.count == 3 }
        check(kept && sent(fake, since: mark).contains(1),
              "while the row reasserts, the rows stay and reading goes on (rows=\(store.entries.count), sent=\(sent(fake, since: mark)))")

        fake.drive(.disconnected)
        let cleared = await settle(within: 2) { store.entries.isEmpty && store.count == 0 }
        check(cleared, "when the session ends, the rows and the count are cleared (rows=\(store.entries.count), count=\(store.count))")
        let ended = fake.messageOpcodes.count
        try? await Task.sleep(for: .seconds(1.2))
        check(sent(fake, since: ended).isEmpty, "and a store whose session ended sends nothing (sent=\(sent(fake, since: ended)))")

        fake.drive(.connecting)
        let rising = await settle(within: 1.5) { row.status == .activating && store.entries.count == 3 }
        check(rising, "when a session is coming up, its lines are read again (status=\(row.status), rows=\(store.entries.count))")
    }

    func aSilentExtensionEndsEachWaitAtFiveSeconds() async {
        guard let rig = rig("Silent") else {
            fail("the rig did not materialize its row")
            return
        }
        let (fake, store) = (rig.fake, rig.store)
        defer { release(store) }
        fake.logReply = .silent

        store.startPolling()
        try? await Task.sleep(for: .seconds(5.2))
        let early = fake.messageOpcodes.filter { $0 == 1 }.count
        check(early == 2, "short of five seconds the wait is still open: nothing more is asked (asked=\(early))")
        try? await Task.sleep(for: .seconds(1.4))
        let asked = fake.messageOpcodes.filter { $0 == 1 }.count
        check(asked >= 3 && store.entries.isEmpty,
              "an unanswered opcode 1 does not freeze the reading: it is asked again after the wait, and no rows show"
              + " (asked=\(asked), rows=\(store.entries.count))")

        store.stopPolling()
        try? await Task.sleep(for: .seconds(0.6))
        let mark = fake.messageOpcodes.count
        try? await Task.sleep(for: .seconds(6))
        check(sent(fake, since: mark).isEmpty,
              "once the log screen lets go, nothing more is sent (sent=\(sent(fake, since: mark)))")
    }

    func aClearEmptiesTheBufferAndTheRows() async {
        guard let rig = rig("Clear") else {
            fail("the rig did not materialize its row")
            return
        }
        let (fake, store) = (rig.fake, rig.store)
        defer { release(store) }

        store.startPolling()
        let read = await settle(within: 1, until: { store.entries.count == 3 })
        guard check(read, "the log screen reads the lines (rows=\(store.entries.count))") else { return }
        let newestBefore = store.entries.map(\.id).max() ?? 0
        let mark = fake.messageOpcodes.count
        await store.clear()
        check(sent(fake, since: mark).contains(2) && store.entries.isEmpty && store.count == 0,
              "clear sends opcode 2 and empties the rows and the count"
              + " (sent=\(sent(fake, since: mark)), rows=\(store.entries.count), count=\(store.count))")

        fake.logLines.append(line(9))
        let arrived = await settle(within: 1.5) { store.entries.count == 1 }
        let newId = store.entries.first?.id ?? 0
        check(arrived && newId > newestBefore,
              "a line logged after it arrives under an id newer than any before (rows=\(store.entries.count), id=\(newId), newest before=\(newestBefore))")
    }

    func rowsKeepTheirIdsWhileTheBufferSlides() async {
        guard let rig = rig("Slide") else {
            fail("the rig did not materialize its row")
            return
        }
        let (fake, store) = (rig.fake, rig.store)
        defer { release(store) }
        fake.logLines[1] = fake.logLines[0]

        store.startPolling()
        let read = await settle(within: 1, until: { store.entries.count == 3 })
        guard check(read, "the log screen reads the lines (rows=\(store.entries.count))") else { return }
        let before = store.entries
        fake.logLines.removeFirst()
        fake.logLines.append(line(4))
        let slid = await settle(within: 1.5) { store.entries.last?.text.hasSuffix("line 4") == true }
        let after = store.entries
        let keptIds = after.count == 3 && after[0].id == before[1].id && after[1].id == before[2].id
        let freshId = after.count == 3 && after[2].id > (before.map(\.id).max() ?? 0)
        check(slid && keptIds && freshId,
              "the lines still present keep their ids and the new one gets a new id"
              + " (before=\(before.map(\.id)), after=\(after.map(\.id)))")
    }

    func anAnswerThatSaysNothingOrDoesNotDecodeKeepsTheRows() async {
        guard let rig = rig("Answers") else {
            fail("the rig did not materialize its row")
            return
        }
        let (fake, store) = (rig.fake, rig.store)
        defer { release(store) }

        store.startPolling()
        let read = await settle(within: 1, until: { store.entries.count == 3 })
        guard check(read, "the log screen reads the lines (rows=\(store.entries.count))") else { return }
        let shown = store.entries

        fake.logReply = .nothing
        var mark = fake.messageOpcodes.count
        let unanswered = await holds(for: 1.2) { store.entries == shown && store.count == 3 }
        check(unanswered && sent(fake, since: mark).contains(1),
              "an opcode 1 answered with nothing keeps the rows and the count"
              + " (rows=\(store.entries.count), count=\(store.count), sent=\(sent(fake, since: mark)))")

        fake.logReply = .garbage
        mark = fake.messageOpcodes.count
        let unread = await holds(for: 1.2) { store.entries == shown && store.count == 3 }
        check(unread && sent(fake, since: mark).contains(1),
              "an answer that does not decode keeps them too"
              + " (rows=\(store.entries.count), count=\(store.count), sent=\(sent(fake, since: mark)))")
    }
}
#endif
