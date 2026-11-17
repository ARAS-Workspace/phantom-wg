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
// Runtime Shutdown (Listeners After Release)
//
// What a component of the app runtime does after `shutDown()`, which
// `AppRuntime.shutDown` calls before the runtime is released. A released
// object can outlive the release: on 2026-11-17 SwiftUI held a closed
// window's responder tree, and through it the tunnels manager, the
// extension gate and the split-tunneling coordinator, until the window
// opened again. A shut-down component reacts to nothing even then.
//
// Each step drives its own component over `FreshSlotFactory` and
// `FaultVaultClient`. Every "reacts to nothing" check comes after a
// positive control that shows the same component reacting before its
// shutdown.
//
// Scenarios:
//
//   A — A Shut-Down Connection Gate Runs No Pass
//       A configuration change posted 100 ms before the shutdown leaves a
//       pending check that the shutdown cancels. Becoming active, a held
//       session's announcement and checkAgain after it load nothing and
//       leave the verdict where it was.
//
//   B — A Shut-Down Connection Gate Arms No Belt
//       A gate shut down while held runs no belt load in 3.6 s. A gate
//       shut down while its first load is still out arms no belt when
//       that load lands on a held verdict.
//
//   C — A Shut-Down Tunnels Manager Reacts To Nothing
//       After a status and a reload that reach it, the manager is shut
//       down 100 ms after a configuration change. That pending refresh,
//       the entry's next status, a later configuration change and becoming
//       active reach nothing.
//
//   D — A Shut-Down Vault Session Ignores Becoming Active
//       A silent session asks the vault again when the app becomes
//       active. A shut-down one leaves its silent state alone.
//
// Not driven here: the extension gate, the split-tunneling provider
// manager, the interface resolver and the tunnels manager loader's bar
// on a late load. Each of those reaches the system, which this workflow
// does not fake.

#if DEBUG
import AppKit
import Foundation
import NetworkExtension

final class RuntimeShutdownWorkflow: TestWorkflow {

    override var displayName: String { "Runtime Shutdown (Listeners After Release)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("A Shut-Down Connection Gate Runs No Pass", gateRunsNoPass),
            WorkflowStep("A Shut-Down Connection Gate Arms No Belt", gateArmsNoBelt),
            WorkflowStep("A Shut-Down Tunnels Manager Reacts To Nothing", managerReactsToNothing),
            WorkflowStep("A Shut-Down Vault Session Ignores Becoming Active", vaultSessionIgnoresActivation),
        ]
    }

    private let runTag = String(UUID().uuidString.prefix(8))

    // MARK: - Steps

    private func gateRunsNoPass() async {
        guard let mine = throwaway("TE-ShutGateOwn") else { return }
        let stranger = foreign("TE-ShutGateForeign", .disconnected)
        let factory = FreshSlotFactory([own(mine, .connected), stranger])
        let gate = ConnectionGateCoordinator(vault: vault(owning: [mine]), providerFactory: factory)
        gate.start()
        guard await settle(within: 2, until: { gate.state == .slotFree }) else {
            return fail("the gate reached no free verdict within 2 s of its start — state=\(String(describing: gate.state))")
        }
        await quiet(1)
        let loads = factory.loadCount

        NotificationCenter.default.post(name: .NEVPNConfigurationChange, object: nil)
        await quiet(0.1)
        gate.shutDown()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        factory.announce(.connected, for: stranger.identity.id)
        gate.checkAgain()
        await quiet(1.5)
        check(factory.loadCount == loads,
              "the check pending at the shutdown, becoming active and checkAgain after it loaded nothing — loads \(loads) → \(factory.loadCount)")
        check(gate.state == .slotFree,
              "and the held foreign session announcing connected ran no pass — state=\(String(describing: gate.state))")
    }

    private func gateArmsNoBelt() async {
        guard let mine = throwaway("TE-ShutBeltOwn") else { return }
        let stranger = foreign("TE-ShutBeltForeign", .connected)
        let held = FreshSlotFactory([own(mine, .disconnected), stranger])
        let gate = ConnectionGateCoordinator(vault: vault(owning: [mine]), providerFactory: held)
        gate.start()
        guard await settle(within: 2, until: { gate.state == .slotHeld(holderName: stranger.identity.name) }) else {
            return fail("the gate did not engage on the foreign session within 2 s — state=\(String(describing: gate.state))")
        }
        let loads = held.loadCount
        gate.shutDown()
        await quiet(3.6)
        check(held.loadCount == loads,
              "a gate shut down while held ran no belt load in 3.6 s — loads \(loads) → \(held.loadCount)")

        let slow = FreshSlotFactory([own(mine, .disconnected), stranger], loadDelay: .milliseconds(500))
        let late = ConnectionGateCoordinator(vault: vault(owning: [mine]), providerFactory: slow)
        late.start()
        await quiet(0.1)
        late.shutDown()
        guard await settle(within: 2, until: { slow.loadCount == 1 }) else {
            return fail("the held-back load never landed — loads=\(slow.loadCount)")
        }
        await quiet(3.6)
        check(slow.loadCount == 1,
              "a gate shut down while its first load was out armed no belt when that load landed — loads=\(slow.loadCount), state=\(String(describing: late.state))")
    }

    private func managerReactsToNothing() async {
        guard let config = throwaway("TE-ShutManager") else { return }
        let identity = TunnelIdentity(id: config.id, name: config.name, createdAt: Date(), isGhost: false)
        let entry = FakeSlotProvider(name: config.name, identity: identity, status: .disconnected)
        let factory = FreshSlotFactory([FreshSlotFactory.Blueprint(identity: identity, status: .disconnected)])
        let manager = TunnelsManager(tunnelProviders: [entry], providerFactory: factory, vault: vault(owning: [config]))
        guard let row = manager.tunnels.first(where: { $0.id == config.id }) else {
            return fail("the manager did not list the planted row")
        }

        entry.drive(.connected)
        guard check(await settle(within: 2) { row.status == .active },
                    "before the shutdown a status the entry announced reached the row — status=\(row.status)") else { return }
        NotificationCenter.default.post(name: .NEVPNConfigurationChange, object: nil)
        guard check(await settle(within: 2) { factory.loadCount == 1 },
                    "and a configuration change reloaded the list — loads=\(factory.loadCount)") else { return }

        NotificationCenter.default.post(name: .NEVPNConfigurationChange, object: nil)
        await quiet(0.1)
        manager.shutDown()
        entry.drive(.disconnected)
        NotificationCenter.default.post(name: .NEVPNConfigurationChange, object: nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await quiet(1.5)
        check(row.status == .active,
              "after the shutdown the entry announcing idle reached nothing — status=\(row.status)")
        check(factory.loadCount == 1,
              "and the refresh pending at the shutdown, a later configuration change and becoming active reloaded nothing — loads=\(factory.loadCount)")
    }

    private func vaultSessionIgnoresActivation() async {
        let control = TunnelVaultSession(vault: FaultVaultClient(), state: .silent)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        guard check(await settle(within: 1) { control.state != .silent },
                    "a silent session asked the vault again when the app became active — state=\(control.state)") else { return }

        let session = TunnelVaultSession(vault: FaultVaultClient(), state: .silent)
        session.shutDown()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await quiet(1)
        check(session.state == .silent,
              "a shut-down session left its silent state alone when the app became active — state=\(session.state)")
    }

    // MARK: - Rig

    private func vault(owning configs: [TunnelConfig]) -> FaultVaultClient {
        let vault = FaultVaultClient()
        vault.readAllAnswer = .answers(.configs(configs))
        vault.readAnswer = .answers(.missing)
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
