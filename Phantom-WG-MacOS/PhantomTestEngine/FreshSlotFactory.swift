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
// Test Engine: Fresh Slot Factory
//
// A `TunnelProviderFactory` that answers every load the way the system
// does: with new provider objects, one per configuration it holds.
// `FakeSlotFactory` hands back the same objects on every load, so it cannot
// show what a caller does with the sessions a load creates.
//
// Each configuration is a blueprint: an identity and the status the system
// holds for it. A load mints one `FakeSlotProvider` per blueprint with that
// status, and each minted provider announces its status once, on the main
// queue after the load has returned: it posts `.NEVPNStatusDidChange` with
// itself as the object.
//
// It stands for the condition measured on 2026-11-17 in the 2.2.0 release
// build, where the connection gate loaded the preferences about every
// 425 ms for hours and every pass left two sessions alive. Which
// notification drove those passes was not measured, so the fake takes the
// worst case: every fresh session announces once.
//
// `announce(_:for:)` moves a configuration's status and posts it from every
// provider minted for it, which is how the system tells each session object
// it handed out. `changeSilently(_:for:)` moves it with no notification,
// for a session in another account whose transitions may never reach this
// process: only the next load sees it.
//
// It counts its loads and keeps every provider it minted, on the main
// actor.

#if DEBUG
import Foundation
import NetworkExtension

@MainActor
final class FreshSlotFactory: TunnelProviderFactory {

    struct Blueprint {
        let identity: TunnelIdentity
        var status: NEVPNStatus
    }

    private var blueprints: [Blueprint]
    private(set) var loadCount = 0
    private(set) var minted: [FakeSlotProvider] = []

    init(_ blueprints: [Blueprint]) {
        self.blueprints = blueprints
    }

    nonisolated func makeProvider() -> TunnelProviding {
        FakeSlotProvider(name: nil, identity: nil, status: .invalid, entryExists: false)
    }

    nonisolated func loadAllFromPreferences() async throws -> [TunnelProviding] {
        await mint()
    }

    func announce(_ status: NEVPNStatus, for id: UUID) {
        changeSilently(status, for: id)
        for provider in minted where provider.tunnelIdentity?.id == id {
            provider.drive(status)
        }
    }

    func changeSilently(_ status: NEVPNStatus, for id: UUID) {
        guard let index = blueprints.firstIndex(where: { $0.identity.id == id }) else { return }
        blueprints[index].status = status
    }

    private func mint() -> [TunnelProviding] {
        loadCount += 1
        let fresh = blueprints.map { blueprint in
            FakeSlotProvider(name: blueprint.identity.name, identity: blueprint.identity, status: blueprint.status)
        }
        minted += fresh
        for provider in fresh {
            DispatchQueue.main.async { provider.drive(provider.connectionStatus) }
        }
        return fresh
    }
}
#endif
