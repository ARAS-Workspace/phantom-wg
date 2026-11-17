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
// Connection Gate (When It Reloads)
//
// What the connection gate does with the notifications it observes, over a
// `FreshSlotFactory` and a `FaultVaultClient`. Nothing here reaches NE
// preferences or the vault daemon, so the workflow also runs outside the
// app. Each step starts a gate of its own and counts that gate's loads,
// whole-vault reads and classifier passes.
//
// It comes from a measurement on 2026-11-17 in the 2.2.0 release build: the
// gate loaded the preferences and read the whole vault about every 425 ms
// for nine hours, every pass left two `NETunnelProviderSession` objects
// alive, and the window opened after that night held the main thread for
// up to 7.6 s at a time. A load answers with new session objects, and the
// gate's status observer took a notification from any session, its own
// fresh ones included.
//
// Scenarios:
//
//   A — A Session's Own Announcement Does Not Reload The Gate
//       The two sessions of the first load announce their status. In the
//       2 s after the first verdict the gate loads once and reads the
//       whole vault once.
//
//   B — A Held Session's Change Engages And Releases Without A Reload
//       A foreign session the gate holds announces connected, then idle.
//       The gate engages on it and releases, with no load.
//
//   C — A Configuration Change Or Becoming Active Reloads Once
//       Each of the two reload triggers costs exactly one load.
//
//   D — A Stranger's Notification Runs No Pass
//       A status notification from a session the gate does not hold runs
//       no classifier pass and no load.
//
//   E — While Held, The Gate Reloads At The Belt's Pace
//       A foreign session's transitions may never reach this process, so a
//       held gate reloads every 3 s. It loads once more in 3.6 s, and a
//       later reload releases the gate when the session leaves without a
//       notification.
//
// D counts classifier passes through a connected session that the
// whole-vault read does not list and its own read claims as ours: the
// classifier asks the vault for it on every pass, and the verdict stays a
// free slot.

#if DEBUG
import AppKit
import Foundation
import NetworkExtension

final class ConnectionGateWorkflow: TestWorkflow {

    override var displayName: String { "Connection Gate (When It Reloads)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("A Session's Own Announcement Does Not Reload The Gate", ownAnnouncementsDoNotReload),
            WorkflowStep("A Held Session's Change Engages And Releases Without A Reload", heldChangeWithoutReload),
            WorkflowStep("A Configuration Change Or Becoming Active Reloads Once", triggersReloadOnce),
            WorkflowStep("A Stranger's Notification Runs No Pass", strangerRunsNoPass),
            WorkflowStep("While Held, The Gate Reloads At The Belt's Pace", heldReloadsAtBeltPace),
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))

    // MARK: - Steps

    private func ownAnnouncementsDoNotReload() async {
        guard let one = throwaway("TE-GateQuietA"), let two = throwaway("TE-GateQuietB") else { return }
        let vault = vault(owning: [one, two])
        guard let rig = await started([own(one, .disconnected), own(two, .connected)], vault) else { return }

        await quiet(2)
        check(rig.factory.loadCount == 1,
              "in the 2 s after its first verdict the gate loaded the preferences once, and the two sessions that load minted announcing their status did not load them again — loads=\(rig.factory.loadCount)")
        check(vault.readAllCount == 1,
              "and it read the whole vault once — readAll=\(vault.readAllCount)")
    }

    private func heldChangeWithoutReload() async {
        guard let mine = throwaway("TE-GateHeldOwn") else { return }
        let stranger = foreign("TE-GateHeldForeign", .disconnected)
        let vault = vault(owning: [mine])
        guard let rig = await started([own(mine, .disconnected), stranger], vault),
              free(rig) else { return }
        await quiet(1)
        let loads = rig.factory.loadCount

        rig.factory.announce(.connected, for: stranger.identity.id)
        let engaged = await settle(within: 2) { rig.gate.state == .slotHeld(holderName: stranger.identity.name) }
        guard check(engaged,
                    "the held foreign session announcing connected engaged the gate on it — state=\(String(describing: rig.gate.state))") else {
            return
        }
        check(rig.factory.loadCount == loads,
              "with no load of the preferences — loads \(loads) → \(rig.factory.loadCount)")

        rig.factory.announce(.disconnected, for: stranger.identity.id)
        let released = await settle(within: 2) { rig.gate.state == .slotFree }
        check(released, "the same session announcing idle released the gate — state=\(String(describing: rig.gate.state))")
        check(rig.factory.loadCount == loads,
              "still with no load — loads \(loads) → \(rig.factory.loadCount)")
    }

    private func triggersReloadOnce() async {
        guard let mine = throwaway("TE-GateTrigger") else { return }
        let vault = vault(owning: [mine])
        guard let rig = await started([own(mine, .connected)], vault) else { return }
        await quiet(1)

        let beforeChange = rig.factory.loadCount
        NotificationCenter.default.post(name: .NEVPNConfigurationChange, object: nil)
        await quiet(1.5)
        check(rig.factory.loadCount == beforeChange + 1,
              "a configuration change loaded the preferences once — loads \(beforeChange) → \(rig.factory.loadCount)")

        let beforeActive = rig.factory.loadCount
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await quiet(1.5)
        check(rig.factory.loadCount == beforeActive + 1,
              "becoming active loaded them once — loads \(beforeActive) → \(rig.factory.loadCount)")
    }

    private func strangerRunsNoPass() async {
        guard let mine = throwaway("TE-GateStrangerOwn"), let claimed = throwaway("TE-GateStrangerClaimed") else { return }
        let vault = vault(owning: [mine], claiming: claimed)
        guard let rig = await started([own(mine, .disconnected), own(claimed, .connected)], vault),
              free(rig) else { return }
        await quiet(1)
        let passes = vault.readIds.count
        let loads = rig.factory.loadCount

        let outsider = foreign("TE-GateOutsider", .disconnected)
        FakeSlotProvider(name: outsider.identity.name, identity: outsider.identity, status: .disconnected).drive(.connected)
        await quiet(1)
        check(vault.readIds.count == passes,
              "a status notification from a session the gate does not hold ran no classifier pass — passes \(passes) → \(vault.readIds.count)")
        check(rig.factory.loadCount == loads,
              "and no load — loads \(loads) → \(rig.factory.loadCount)")
    }

    private func heldReloadsAtBeltPace() async {
        guard let mine = throwaway("TE-GateBeltOwn") else { return }
        let stranger = foreign("TE-GateBeltForeign", .connected)
        let vault = vault(owning: [mine])
        guard let rig = await started([own(mine, .disconnected), stranger], vault) else { return }
        guard rig.gate.state == .slotHeld(holderName: stranger.identity.name) else {
            return fail("the rig did not engage the gate on the foreign session — state=\(String(describing: rig.gate.state))")
        }
        let loads = rig.factory.loadCount

        await quiet(3.6)
        check(rig.factory.loadCount == loads + 1,
              "held for 3.6 s, the gate loaded the preferences once more: the 3 s belt and nothing faster — loads \(loads) → \(rig.factory.loadCount)")

        rig.factory.changeSilently(.disconnected, for: stranger.identity.id)
        let released = await settle(within: 4) { rig.gate.state == .slotFree }
        check(released,
              "with the foreign session gone and no notification, a later belt load released the gate — state=\(String(describing: rig.gate.state))")
    }

    // MARK: - Rig

    private struct Rig {
        let gate: ConnectionGateCoordinator
        let factory: FreshSlotFactory
    }

    private func started(_ blueprints: [FreshSlotFactory.Blueprint], _ vault: FaultVaultClient) async -> Rig? {
        let factory = FreshSlotFactory(blueprints)
        let gate = ConnectionGateCoordinator(vault: vault, providerFactory: factory)
        gate.start()
        guard await settle(within: 2, until: { gate.state != .checking }) else {
            fail("the gate reached no verdict within 2 s of its start — state=\(String(describing: gate.state))")
            return nil
        }
        return Rig(gate: gate, factory: factory)
    }

    private func free(_ rig: Rig) -> Bool {
        guard rig.gate.state == .slotFree else {
            fail("the rig's first verdict is not a free slot — state=\(String(describing: rig.gate.state))")
            return false
        }
        return true
    }

    private func vault(owning configs: [TunnelConfig], claiming claimed: TunnelConfig? = nil) -> FaultVaultClient {
        let vault = FaultVaultClient()
        vault.readAllAnswer = .answers(.configs(configs))
        vault.readAnswer = .answers(.missing)
        if let claimed { vault.readAnswers[claimed.id] = .answers(.config(claimed)) }
        return vault
    }

    private func throwaway(_ name: String) -> TunnelConfig? {
        guard let config = TestConfigFactory.throwaway(name: "\(name)-\(runTag)") else {
            fail("the config factory did not produce the throwaway '\(name)' this step needs")
            return nil
        }
        return config
    }

    private func own(_ config: TunnelConfig, _ status: NEVPNStatus) -> FreshSlotFactory.Blueprint {
        FreshSlotFactory.Blueprint(
            identity: TunnelIdentity(id: config.id, name: config.name, createdAt: Date(), isGhost: false),
            status: status
        )
    }

    private func foreign(_ name: String, _ status: NEVPNStatus) -> FreshSlotFactory.Blueprint {
        FreshSlotFactory.Blueprint(
            identity: TunnelIdentity(id: UUID(), name: "\(name)-\(runTag)", createdAt: Date(), isGhost: false),
            status: status
        )
    }

    private func quiet(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
#endif
