// Activation Seam
//
// The iOS subset of the activation seam: the queue a press on a busy slot
// opens, the hand-off that ends it, and the list refreshes and removals
// that cross it. Mac's ActivationSeam family is the source; the steps here
// cover what iOS's `TunnelsManager` carries.
//
// Everything runs over a `TunnelsManager` of the step's own, whose rows are
// `FakeSlotProvider`s (in memory) handed both as the opening rows and as
// the factory's canned answer. A fake answers only notifications that
// carry itself, so the app's own manager never reacts to a driven status.
// Step G posts `NEVPNConfigurationChange`, which every live manager answers
// with a reload; the app's own reload reads the system and changes nothing.
//
// Scenarios:
//
//   A — A Press On A Busy Slot Queues And Stops The Occupant
//       A holds a session; a press on B queues B and stops A. When A's
//       session ends, B takes its turn.
//
//   B — A Second Queued Press Takes The Slot
//       With B queued behind A, a press on C queues C, returns B to rest,
//       and sends A no second stop. When A's session ends, C starts and B
//       does not.
//
//   C — A Queued Row Toggled Off Gives Up Its Turn
//       With B queued behind A, toggling B off returns it to rest and frees
//       the slot. When A's session ends, B does not start.
//
//   D — A List Refresh Cannot Cancel An Activation
//       While B's activation waits on its arm save, refreshes reading
//       disconnected, invalid and disconnecting leave it activating; the
//       activation still reaches startTunnel, and a connected refresh
//       lands.
//
//   E — A List Refresh Cannot Take A Queued Tunnel's Turn
//       With B queued behind A and C idle but armed, a refresh and a
//       disconnecting reading leave B queued, and so does a driven
//       disconnected notification for B. When A's session ends, B takes
//       its turn and the hand-off stands C's rule down in the store.
//
//   F — A Removal Hands The Queue On Only When The Slot Is Free
//       With B queued behind A going down, removing a bystander leaves B
//       queued; removing A hands the queue on.
//
//   G — A Queue Slot Whose Tunnel Left The List Is Discarded
//       With B queued behind A going down, B's entry leaves the system and
//       a reload drops its row. The slot is discarded, and when A's session
//       ends no session is raised for B.
//
// The recovery rule's steps (H to R) are in
// `ActivationSeamWorkflow+RecoveryRule.swift`.

#if DEBUG
import Foundation
import NetworkExtension

final class ActivationSeamWorkflow: TestWorkflow {
    override var displayName: String { "Activation Seam (The Queue, Its Hand-Off And The Recovery Rule)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("A Press On A Busy Slot Queues And Stops The Occupant", aPressOnABusySlotQueuesAndStopsTheOccupant),
            WorkflowStep("A Second Queued Press Takes The Slot", aSecondQueuedPressTakesTheSlot),
            WorkflowStep("A Queued Row Toggled Off Gives Up Its Turn", aQueuedRowToggledOffGivesUpItsTurn),
            WorkflowStep("A List Refresh Cannot Cancel An Activation", aListRefreshCannotCancelAnActivation),
            WorkflowStep("A List Refresh Cannot Take A Queued Tunnel's Turn", aListRefreshCannotTakeAQueuedTunnelsTurn),
            WorkflowStep("A Removal Hands The Queue On Only When The Slot Is Free", aRemovalHandsTheQueueOnOnlyWhenTheSlotIsFree),
            WorkflowStep("A Queue Slot Whose Tunnel Left The List Is Discarded", aQueueSlotWhoseTunnelLeftTheListIsDiscarded),
            WorkflowStep("The Armed Rule Is One Connect Rule For Any Interface", theArmedRuleIsOneConnectRuleForAnyInterface),
            WorkflowStep("A Stop Stands The Rule Down Before It Goes Out", aStopStandsTheRuleDownBeforeItGoesOut),
            WorkflowStep("A Refused Disarm Surfaces And The Stop Still Goes Out", aRefusedDisarmSurfacesAndTheStopStillGoesOut),
            WorkflowStep("The Sweep Reaches A Rule The Flag Denies", theSweepReachesARuleTheFlagDenies),
            WorkflowStep("A Stop Reaches A Rule The Flag Denies", aStopReachesARuleTheFlagDenies),
            WorkflowStep("A Config That Will Not Load Loses Its Rule", aConfigThatWillNotLoadLosesItsRule),
            WorkflowStep("A Start The System Refuses Loses Its Rule", aStartTheSystemRefusesLosesItsRule),
            WorkflowStep("The Ladder Running Out Leaves The Rule Armed", theLadderRunningOutLeavesTheRuleArmed),
            WorkflowStep("A Drop Mid-Activation Files The System's Record", aDropMidActivationFilesTheSystemsRecord),
            WorkflowStep("A Mute Drop Files A Stand-In Error", aMuteDropFilesAStandInError),
            WorkflowStep("A Stop The Rule Save Cannot Answer Still Goes Out", aStopTheRuleSaveCannotAnswerStillGoesOut)
        ]
    }

    let runTag = String(UUID().uuidString.prefix(8))

    // MARK: - Rig

    struct Rig {
        let manager: TunnelsManager
        let fakes: [FakeSlotProvider]
        let rows: [TunnelContainer]
    }

    /// One fake per status, named `TE-Seam-<label>-<n>`; the first fake is
    /// enabled when it opens connected, as the system's one enabled entry.
    /// `pacing` sets the manager's retry interval and rung count.
    func rig(_ label: String, _ statuses: [NEVPNStatus],
             pacing: (interval: TimeInterval, rungs: Int) = (5.0, 8)) -> Rig? {
        var configs: [TunnelConfig] = []
        for index in statuses.indices {
            guard let config = TestConfigFactory.throwaway(name: "TE-Seam-\(label)\(index + 1)-\(runTag)") else { return nil }
            configs.append(config)
        }
        let fakes = zip(configs, statuses).map { FakeSlotProvider(config: $0, status: $1) }
        if let first = fakes.first, first.connectionStatus == .connected { first.isEnabled = true }
        let manager = TunnelsManager(tunnelProviders: fakes, providerFactory: FakeSlotFactory(canned: fakes),
                                     retryInterval: pacing.interval, maxRetries: pacing.rungs)
        let rows = configs.compactMap { config in manager.tunnels.first { $0.id == config.id } }
        guard rows.count == configs.count else { return nil }
        return Rig(manager: manager, fakes: fakes, rows: rows)
    }

    /// True when `condition` holds for the whole window.
    func holds(for seconds: Double, _ condition: () -> Bool) async -> Bool {
        let watch = Date()
        while Date().timeIntervalSince(watch) < seconds {
            if !condition() { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    // MARK: - Steps

    func aPressOnABusySlotQueuesAndStopsTheOccupant() async {
        guard let rig = rig("Busy", [.connected, .disconnected]) else {
            fail("the rig did not materialize its two rows")
            return
        }
        let (manager, fakeA, fakeB, rowA, rowB) = (rig.manager, rig.fakes[0], rig.fakes[1], rig.rows[0], rig.rows[1])
        guard check(rowA.status == .active, "the rig's first row opens active (status=\(rowA.status))") else { return }

        manager.startActivation(of: rowB)
        check(rowB.status == .waiting && manager.waitingTunnel === rowB,
              "the press on the busy slot queues B (status=\(rowB.status), queued=\(manager.waitingTunnel === rowB))")
        check(rowA.status == .deactivating && fakeA.stopCount == 1,
              "and stops A (status=\(rowA.status), stops=\(fakeA.stopCount))")

        fakeA.drive(.disconnected)
        let tookItsTurn = await settle(within: 3) { fakeB.startCount >= 1 }
        check(tookItsTurn && manager.waitingTunnel == nil,
              "when A's session ends, B takes its turn (starts=\(fakeB.startCount), status=\(rowB.status))")
    }

    func aSecondQueuedPressTakesTheSlot() async {
        guard let rig = rig("Second", [.connected, .disconnected, .disconnected]) else {
            fail("the rig did not materialize its three rows")
            return
        }
        let (manager, fakeA, fakeB, fakeC) = (rig.manager, rig.fakes[0], rig.fakes[1], rig.fakes[2])
        let (rowB, rowC) = (rig.rows[1], rig.rows[2])

        manager.startActivation(of: rowB)
        guard check(rowB.status == .waiting, "B queues behind A (status=\(rowB.status))") else { return }
        manager.startActivation(of: rowC)
        check(rowC.status == .waiting && manager.waitingTunnel === rowC && rowB.status == .inactive,
              "a press on C takes the slot and returns B to rest (C=\(rowC.status), B=\(rowB.status))")
        check(fakeA.stopCount == 1, "and A is sent no second stop (stops=\(fakeA.stopCount))")

        fakeA.drive(.disconnected)
        let cStarted = await settle(within: 3) { fakeC.startCount >= 1 }
        check(cStarted && fakeB.startCount == 0,
              "when A's session ends, C starts and B does not (C starts=\(fakeC.startCount), B starts=\(fakeB.startCount))")
    }

    func aQueuedRowToggledOffGivesUpItsTurn() async {
        guard let rig = rig("Toggle", [.connected, .disconnected]) else {
            fail("the rig did not materialize its two rows")
            return
        }
        let (manager, fakeA, fakeB, rowB) = (rig.manager, rig.fakes[0], rig.fakes[1], rig.rows[1])

        manager.startActivation(of: rowB)
        guard check(rowB.status == .waiting, "B queues behind A (status=\(rowB.status))") else { return }
        manager.startDeactivation(of: rowB)
        check(rowB.status == .inactive && manager.waitingTunnel == nil,
              "toggling B off returns it to rest and frees the slot (status=\(rowB.status), queued=\(manager.waitingTunnel != nil))")

        fakeA.drive(.disconnected)
        let stayedDown = await holds(for: 1) { fakeB.startCount == 0 }
        check(stayedDown, "when A's session ends, B does not start (starts=\(fakeB.startCount))")
    }

    func aListRefreshCannotCancelAnActivation() async {
        guard let rig = rig("Refresh", [.disconnected]) else {
            fail("the rig did not materialize its row")
            return
        }
        let (manager, fake, row) = (rig.manager, rig.fakes[0], rig.rows[0])
        fake.saveAnswer = .succeedsAfter(seconds: 1.5)

        manager.startActivation(of: row)
        guard await settle(within: 3, until: { fake.saveCount >= 1 }) else {
            skip("environment: the activation never reached its arm save")
            return
        }
        row.refreshStatus()
        check(row.status == .activating, "a disconnected refresh leaves the activation alone (status=\(row.status))")
        fake.setStatusSilently(.invalid)
        row.refreshStatus()
        check(row.status == .activating, "an invalid refresh leaves it alone (status=\(row.status))")
        fake.setStatusSilently(.disconnecting)
        row.refreshStatus()
        check(row.status == .activating, "a disconnecting refresh leaves it alone (status=\(row.status))")

        let started = await settle(within: 4) { fake.startCount >= 1 }
        check(started, "the activation still reaches startTunnel (starts=\(fake.startCount))")
        guard check(row.isManagerDriven, "the row is still manager-driven, so the next claim has something to measure") else { return }
        fake.setStatusSilently(.connected)
        row.refreshStatus()
        check(row.status == .active, "a connected refresh lands (status=\(row.status))")
    }

    func aListRefreshCannotTakeAQueuedTunnelsTurn() async {
        guard let rig = rig("Queue", [.connected, .disconnected, .disconnected]) else {
            fail("the rig did not materialize its three rows")
            return
        }
        let (manager, fakeA, fakeB, fakeC, rowB) = (rig.manager, rig.fakes[0], rig.fakes[1], rig.fakes[2], rig.rows[1])
        fakeC.arrangeArmed()

        manager.startActivation(of: rowB)
        guard check(rowB.status == .waiting, "B queues behind A (status=\(rowB.status))") else { return }
        rowB.refreshStatus()
        check(rowB.status == .waiting, "the queue slot survives a list refresh (status=\(rowB.status))")
        fakeB.setStatusSilently(.disconnecting)
        rowB.refreshStatus()
        check(rowB.status == .waiting, "a disconnecting refresh leaves the queue slot alone (status=\(rowB.status))")
        fakeB.drive(.disconnected)
        let slotHeld = await holds(for: 0.5) { rowB.status == .waiting }
        check(slotHeld, "a driven disconnected notification for B leaves the queue slot alone (status=\(rowB.status))")

        fakeA.drive(.disconnected)
        let tookItsTurn = await settle(within: 3) { fakeB.startCount >= 1 }
        check(tookItsTurn, "when A's session ends, B takes its turn (starts=\(fakeB.startCount))")
        let sweptC = await settle(within: 3) { !fakeC.storedOnDemand }
        check(sweptC && !fakeC.isOnDemandEnabled && !fakeC.storedEnabled,
              "the hand-off stands C's rule down in the store, saved disabled"
              + " (store=\(fakeC.storedOnDemand), flag=\(fakeC.isOnDemandEnabled), enabled=\(fakeC.storedEnabled))")
    }

    func aRemovalHandsTheQueueOnOnlyWhenTheSlotIsFree() async {
        guard let rig = rig("Removal", [.connected, .disconnected, .disconnected]) else {
            fail("the rig did not materialize its three rows")
            return
        }
        let (manager, fakeB) = (rig.manager, rig.fakes[1])
        let (rowA, rowB, rowC) = (rig.rows[0], rig.rows[1], rig.rows[2])

        manager.startActivation(of: rowB)
        guard check(rowB.status == .waiting && rowA.status == .deactivating,
                    "B queues behind A going down (B=\(rowB.status), A=\(rowA.status))") else { return }

        do {
            try await manager.remove(tunnel: rowC)
        } catch {
            fail("removing the bystander was refused (\(error))")
            return
        }
        check(!manager.tunnels.contains { $0.id == rowC.id } && manager.waitingTunnel === rowB,
              "the bystander leaves the list and the slot is still held for B")
        let startedEarly = await settle(within: 1) { fakeB.startCount > 0 }
        check(!startedEarly && rowB.status == .waiting,
              "the removal starts no session for B while A is still going down (starts=\(fakeB.startCount), status=\(rowB.status))")

        do {
            try await manager.remove(tunnel: rowA)
        } catch {
            fail("removing the occupant was refused (\(error))")
            return
        }
        let tookItsTurn = await settle(within: 3) { fakeB.startCount >= 1 }
        check(tookItsTurn, "removing the occupant hands the queue on (starts=\(fakeB.startCount))")
    }

    func aQueueSlotWhoseTunnelLeftTheListIsDiscarded() async {
        guard let rig = rig("Stale", [.connected, .disconnected]) else {
            fail("the rig did not materialize its two rows")
            return
        }
        let (manager, fakeA, fakeB, rowB) = (rig.manager, rig.fakes[0], rig.fakes[1], rig.rows[1])

        manager.startActivation(of: rowB)
        guard check(rowB.status == .waiting, "B queues behind A (status=\(rowB.status))") else { return }

        try? await fakeB.removePreferences()
        NotificationCenter.default.post(name: .NEVPNConfigurationChange, object: nil)
        guard await settle(within: 3, until: { !manager.tunnels.contains { $0.id == rowB.id } }) else {
            skip("environment: the reload kept B's row, so there is no stale slot to discard")
            return
        }
        check(manager.waitingTunnel == nil, "the slot of the row the list dropped is discarded")

        fakeA.drive(.disconnected)
        let stayedDown = await holds(for: 1) { fakeB.startCount == 0 }
        check(stayedDown, "when A's session ends, no session is raised for B (starts=\(fakeB.startCount))")
    }
}
#endif
