// Activation Seam: The Recovery Rule
//
// What an activation arms, what a stop and the sweep stand down, and which
// give-up endings take the rule with them. Same rig as the queue steps: a
// `TunnelsManager` of the step's own over in-memory `FakeSlotProvider`s.
// "The store" is the copy the fake's last landed save wrote.
//
// Scenarios:
//
//   H — The Armed Rule Is One Connect Rule For Any Interface
//       An activation that reaches startTunnel has armed one
//       `NEOnDemandRuleConnect` matching any interface, and the store holds
//       it armed and enabled.
//
//   I — A Stop Stands The Rule Down Before It Goes Out
//       A stop on an armed row saves the rule down first; while that save
//       is unanswered no stop goes out, and the stop follows once the store
//       holds the rule down.
//
//   J — A Refused Disarm Surfaces And The Stop Still Goes Out
//       The stop's stand-down save is refused: the stop still goes out, the
//       refusal is the row's `stopDisarmRefused` carrying the system's
//       error, nothing is loaded back,
//       the flag holds the manager's write while the store holds what the
//       refusal left, and the row rests once the session ends.
//
//   K — The Sweep Reaches A Rule The Flag Denies
//       An idle row whose flag reads down while its rule is still set and
//       stored armed is stood down in the store by another row's rung 0.
//
//   L — A Stop Reaches A Rule The Flag Denies
//       The same shape on a row holding a session: its stop saves the rule
//       down in the store and goes out.
//
//   M — A Config That Will Not Load Loses Its Rule
//       The load after the arm save is refused: the row rests with
//       `loadingFailed` carrying the system's error, the attempt is over,
//       the store holds the rule down, and no session was raised.
//
//   N — A Start The System Refuses Loses Its Rule
//       `startTunnel` throws: the row rests with `startingFailed` carrying
//       the system's error, the store holds the rule down, and the attempt
//       is over.
//
//   O — The Ladder Running Out Leaves The Rule Armed
//       Over a manager paced at 0.1 s and three rungs, a session that never
//       answers runs the ladder out: the row rests with
//       `retryLimitReached`, after one start per rung, and the rule stays
//       armed in the store.
//
//   P — A Drop Mid-Activation Files The System's Record
//       The session ends while the activation waits on it, and the system
//       holds a record of why: the row rests with `failedWhileActivating`
//       carrying that record.
//
//   Q — A Mute Drop Files A Stand-In Error
//       The same drop with no record: `failedWhileActivating` carries the
//       app's stand-in (PhantomWG, code -1).
//
//   R — A Stop The Rule Save Cannot Answer Still Goes Out
//       A stop on an armed row whose stand-down save the system holds and
//       does not answer: the save goes out first and the stop waits on it,
//       and the stop still goes out within a few seconds (Mac 2.2.1 waits
//       three). The row says the rule's stand-down was not confirmed, and
//       when the held save answers late (here a refusal) no second stop
//       goes out and nothing is written over that sentence.
//
//   S — A Give-Up Whose Disarm Save Hangs Still Hands The Queue On
//       A's activation waits on a held load; a press on B queues B and
//       stops A. The held load is answered with an error, and the
//       give-up's stand-down save is held unanswered: A rests with
//       `loadingFailed`, and B still takes its turn within a few seconds.

#if DEBUG
import Foundation
import NetworkExtension

extension ActivationSeamWorkflow {

    private func refusal(_ code: Int, _ text: String) -> NSError {
        NSError(domain: "TE.Seam", code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private func describe(_ error: TunnelActivationError?) -> String {
        error.map { String(describing: $0) } ?? "nil"
    }

    /// True when `error` is this file's rig refusal with that code.
    private func carries(_ error: Error?, code: Int) -> Bool {
        guard let error else { return false }
        let nsError = error as NSError
        return nsError.domain == "TE.Seam" && nsError.code == code
    }

    func theArmedRuleIsOneConnectRuleForAnyInterface() async {
        guard let rig = rig("Arm", [.disconnected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])
        manager.startActivation(of: row)
        let started = await settle(within: 3) { fake.startCount >= 1 }
        guard check(started, "the activation reaches startTunnel (starts=\(fake.startCount))") else { return }
        let rules = fake.onDemandRules ?? []
        let connect = rules.first as? NEOnDemandRuleConnect
        check(rules.count == 1 && connect?.interfaceTypeMatch == .any,
              "the activation armed one connect rule for any interface"
              + " (rules=\(rules.count), connect=\(connect != nil), any=\(connect?.interfaceTypeMatch == .any))")
        check(fake.isOnDemandEnabled && fake.storedOnDemand && fake.storedEnabled,
              "and the store holds it armed and enabled (flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand), enabled=\(fake.storedEnabled))")
    }

    func aStopStandsTheRuleDownBeforeItGoesOut() async {
        guard let rig = rig("Stop", [.connected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])
        fake.arrangeArmed()
        fake.saveAnswer = .succeedsAfter(seconds: 0.6)

        manager.startDeactivation(of: row)
        let saveIssued = await settle(within: 1) { fake.saveCount >= 1 }
        check(saveIssued && fake.saveCount == 1 && !fake.isOnDemandEnabled,
              "the stop saves the rule down first (saves=\(fake.saveCount), flag=\(fake.isOnDemandEnabled))")
        let withheld = await holds(for: 0.3) { fake.stopCount == 0 }
        check(withheld, "no stop goes out while that save is unanswered (stops=\(fake.stopCount))")
        let stopped = await settle(within: 3) { fake.stopCount >= 1 }
        check(stopped && !fake.storedOnDemand,
              "the stop follows once the store holds the rule down (stops=\(fake.stopCount), store=\(fake.storedOnDemand))")
    }

    func aRefusedDisarmSurfacesAndTheStopStillGoesOut() async {
        guard let rig = rig("Refused", [.connected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])
        fake.arrangeArmed()
        fake.saveAnswer = .fails(refusal(43, "test rig refused the stand-down save"))
        let loadsBefore = fake.loadCount

        manager.startDeactivation(of: row)
        let stopped = await settle(within: 3) { fake.stopCount >= 1 }
        check(stopped, "the stop still goes out past the refused save (stops=\(fake.stopCount))")
        var surfaced = false
        var carried: Error?
        if case .stopDisarmRefused(let error) = row.lastActivationError {
            surfaced = true
            carried = error
        }
        check(surfaced, "the refusal is the row's stopDisarmRefused (error=\(describe(row.lastActivationError)))")
        check(carries(carried, code: 43), "and it carries the system's refusal")
        check(fake.loadCount == loadsBefore, "nothing is loaded back after it (loads=\(fake.loadCount), before=\(loadsBefore))")
        check(!fake.isOnDemandEnabled && fake.storedOnDemand,
              "the flag holds the manager's write while the store holds what the refusal left"
              + " (flag=\(fake.isOnDemandEnabled), store=\(fake.storedOnDemand))")

        fake.drive(.disconnected)
        let rested = await settle(within: 3) { row.status == .inactive }
        check(rested, "the row rests once the session ends (status=\(row.status))")
    }

    func theSweepReachesARuleTheFlagDenies() async {
        guard let rig = rig("Sweep", [.disconnected, .disconnected]) else {
            fail("the rig did not materialize its two rows")
            return
        }
        let (manager, fakeB, rowA) = (rig.manager, rig.fakes[1], rig.rows[0])
        fakeB.arrangeArmed()
        fakeB.isOnDemandEnabled = false
        guard check(!fakeB.isOnDemandEnabled && fakeB.onDemandRules?.isEmpty == false && fakeB.storedOnDemand,
                    "B's flag reads down while its rule is set and stored armed") else { return }
        let savesBefore = fakeB.saveCount

        manager.startActivation(of: rowA)
        let swept = await settle(within: 3) { !fakeB.storedOnDemand }
        check(swept && fakeB.saveCount > savesBefore,
              "A's rung 0 stands B's rule down in the store (store=\(fakeB.storedOnDemand), saves=\(fakeB.saveCount))")
    }

    func aStopReachesARuleTheFlagDenies() async {
        guard let rig = rig("StopRule", [.connected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])
        fake.arrangeArmed()
        fake.isOnDemandEnabled = false
        guard check(!fake.isOnDemandEnabled && fake.onDemandRules?.isEmpty == false && fake.storedOnDemand,
                    "the row's flag reads down while its rule is set and stored armed") else { return }

        manager.startDeactivation(of: row)
        let stopped = await settle(within: 3) { fake.stopCount >= 1 }
        check(stopped && !fake.storedOnDemand,
              "its stop saves the rule down in the store and goes out (store=\(fake.storedOnDemand), stops=\(fake.stopCount))")
    }

    func aConfigThatWillNotLoadLosesItsRule() async {
        guard let rig = rig("Load", [.disconnected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])
        fake.loadAnswer = .fails(refusal(46, "test rig refused the load"))

        manager.startActivation(of: row)
        let rests = "the row rests with loadingFailed and the attempt is over"
        guard await settle(within: 3, until: { row.lastActivationError != nil }) else {
            check(false, rests + " (no error was filed, status=\(row.status))")
            return
        }
        var named = false
        var carried: Error?
        if case .loadingFailed(let error) = row.lastActivationError {
            named = true
            carried = error
        }
        check(named && row.status == .inactive && !row.isAttemptingActivation,
              rests + " (error=\(describe(row.lastActivationError)), status=\(row.status), attempting=\(row.isAttemptingActivation))")
        check(carries(carried, code: 46), "and the error it files carries the system's refusal")
        let disarmed = await settle(within: 3) { !fake.storedOnDemand }
        check(disarmed, "the store holds the rule down (store=\(fake.storedOnDemand), flag=\(fake.isOnDemandEnabled))")
        check(fake.startCount == 0, "and no session was raised (starts=\(fake.startCount))")
    }

    func aStartTheSystemRefusesLosesItsRule() async {
        guard let rig = rig("Start", [.disconnected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])
        fake.startAnswer = .fails(refusal(47, "test rig refused the start"))

        manager.startActivation(of: row)
        let rests = "the row rests with startingFailed"
        guard await settle(within: 3, until: { row.lastActivationError != nil }) else {
            check(false, rests + " (no error was filed, status=\(row.status))")
            return
        }
        var named = false
        var carried: Error?
        if case .startingFailed(let error) = row.lastActivationError {
            named = true
            carried = error
        }
        check(named && row.status == .inactive,
              rests + " (error=\(describe(row.lastActivationError)), status=\(row.status))")
        check(carries(carried, code: 47), "and the error it files carries the system's refusal")
        let disarmed = await settle(within: 3) { !fake.storedOnDemand }
        check(disarmed, "the store holds the rule down (store=\(fake.storedOnDemand), flag=\(fake.isOnDemandEnabled))")
        check(!row.isAttemptingActivation, "and the attempt is over (attempting=\(row.isAttemptingActivation))")
    }

    func theLadderRunningOutLeavesTheRuleArmed() async {
        let rungs = 3
        guard let rig = rig("Ladder", [.disconnected], pacing: (0.1, rungs)) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])

        manager.startActivation(of: row)
        let rests = "the row rests with retryLimitReached"
        guard await settle(within: 4, until: { row.lastActivationError != nil }) else {
            check(false, rests + " (the ladder never ran out: starts=\(fake.startCount), status=\(row.status))")
            return
        }
        var named = false
        if case .retryLimitReached = row.lastActivationError { named = true }
        check(named && row.status == .inactive,
              rests + " (error=\(describe(row.lastActivationError)), status=\(row.status))")
        check(fake.startCount == rungs, "after one start per rung (starts=\(fake.startCount), rungs=\(rungs))")
        let armed = await holds(for: 0.3) { fake.storedOnDemand && fake.isOnDemandEnabled }
        check(armed, "and the rule stays armed in the store (store=\(fake.storedOnDemand), flag=\(fake.isOnDemandEnabled))")
    }

    func aDropMidActivationFilesTheSystemsRecord() async {
        guard let rig = rig("Drop", [.disconnected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])
        fake.disconnectAnswer = .record(refusal(51, "test rig disconnect record"))

        manager.startActivation(of: row)
        let started = await settle(within: 3) { fake.startCount >= 1 }
        guard check(started, "the activation reaches startTunnel (starts=\(fake.startCount))") else { return }
        fake.drive(.disconnected)
        let rests = "the row rests with failedWhileActivating carrying the system's record"
        guard await settle(within: 3, until: { row.lastActivationError != nil }) else {
            check(false, rests + " (the drop filed no error, status=\(row.status))")
            return
        }
        var record = false
        if case .failedWhileActivating(let error) = row.lastActivationError {
            let nsError = error as NSError
            record = nsError.domain == "TE.Seam" && nsError.code == 51
        }
        check(record && row.status == .inactive,
              rests + " (error=\(describe(row.lastActivationError)), status=\(row.status))")
    }

    func aMuteDropFilesAStandInError() async {
        guard let rig = rig("Mute", [.disconnected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])

        manager.startActivation(of: row)
        let started = await settle(within: 3) { fake.startCount >= 1 }
        guard check(started, "the activation reaches startTunnel (starts=\(fake.startCount))") else { return }
        fake.drive(.disconnected)
        let filed = await settle(within: 3) { row.lastActivationError != nil }
        var standIn = false
        if case .failedWhileActivating(let error) = row.lastActivationError {
            let nsError = error as NSError
            standIn = nsError.domain == "PhantomWG" && nsError.code == -1
        }
        check(filed && standIn,
              "with no record, failedWhileActivating carries the app's stand-in (error=\(describe(row.lastActivationError)))")
    }

    func aStopTheRuleSaveCannotAnswerStillGoesOut() async {
        guard let rig = rig("Patience", [.connected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])
        fake.arrangeArmed()
        fake.saveAnswer = .hangs
        onTeardown("release the held stand-down save") { [weak self] in
            let released = fake.releaseHeldCompletions()
            self?.log("teardown: released \(released) held save(s) of the patience rig")
        }

        manager.startDeactivation(of: row)
        let saveIssued = await settle(within: 1) { fake.saveCount >= 1 }
        guard check(saveIssued && fake.stopCount == 0,
                    "the stand-down save goes out first and the stop waits on it (saves=\(fake.saveCount), stops=\(fake.stopCount))")
        else { return }
        let stopped = await settle(within: 5) { fake.stopCount >= 1 }
        guard check(stopped,
                    "a stand-down save the system does not answer holds the stop no longer than a few seconds (stops=\(fake.stopCount))")
        else { return }
        var said = false
        if case .stopRuleStandDownUnconfirmed = row.lastActivationError { said = true }
        check(said, "the row says the rule's stand-down was not confirmed (error=\(describe(row.lastActivationError)))")

        let released = fake.releaseHeldCompletions()
        let oneStop = await holds(for: 0.5) { fake.stopCount == 1 }
        var stillSaid = false
        if case .stopRuleStandDownUnconfirmed = row.lastActivationError { stillSaid = true }
        check(released == 1 && oneStop && stillSaid,
              "the held save answering late sends no second stop and writes nothing over that sentence"
              + " (released=\(released), stops=\(fake.stopCount), error=\(describe(row.lastActivationError)))")
    }

    func aGiveUpWhoseDisarmSaveHangsStillHandsTheQueueOn() async {
        guard let rig = rig("GiveUp", [.disconnected, .disconnected]) else {
            fail("the rig did not materialize its two rows")
            return
        }
        let (manager, fakeA, fakeB, rowA, rowB) = (rig.manager, rig.fakes[0], rig.fakes[1], rig.rows[0], rig.rows[1])
        onTeardown("release the give-up rig's held requests") { [weak self] in
            let released = fakeA.releaseHeldCompletions()
            self?.log("teardown: released \(released) held request(s) of the give-up rig")
        }
        fakeA.loadAnswer = .hangs

        manager.startActivation(of: rowA)
        let reachedLoad = await settle(within: 2) { fakeA.loadCount >= 1 }
        guard check(reachedLoad, "A's activation reaches its load (loads=\(fakeA.loadCount))") else { return }
        manager.startActivation(of: rowB)
        guard check(rowB.status == .waiting, "B queues behind A's activation (status=\(rowB.status))") else { return }
        let stopped = await settle(within: 2) { fakeA.stopCount >= 1 }
        guard check(stopped, "and A's stop goes out (stops=\(fakeA.stopCount))") else { return }

        fakeA.saveAnswer = .hangs
        let released = fakeA.releaseHeldCompletions()
        guard check(released == 1, "A's held load is answered with an error (released=\(released))") else { return }
        let givesUp = "A gives up with loadingFailed"
        guard await settle(within: 2, until: { rowA.lastActivationError != nil }) else {
            check(false, givesUp + " (no error was filed, status=\(rowA.status))")
            return
        }
        var named = false
        if case .loadingFailed = rowA.lastActivationError { named = true }
        check(named && rowA.status == .inactive,
              givesUp + " (error=\(describe(rowA.lastActivationError)), status=\(rowA.status))")
        let tookItsTurn = await settle(within: 5) { fakeB.startCount >= 1 }
        check(tookItsTurn,
              "with A's stand-down save held unanswered, B still takes its turn within a few seconds (starts=\(fakeB.startCount))")
    }
}
#endif
