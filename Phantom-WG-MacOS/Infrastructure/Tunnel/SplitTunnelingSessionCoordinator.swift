import Foundation
import Observation
import os.log

/// Single source of truth for the Split-Tunneling feature's runtime
/// state. The UI toggle binds to `state.isUserVisiblyActive`; the
/// coordinator drives both managers in lockstep at the preference
/// layer and pushes live config updates to both extensions over
/// their `ProxyConfigDaemon` XPC channels (`applyConfig`). The two
/// extensions run independently — they do not monitor or coordinate
/// with each other.
@Observable
@MainActor
final class SplitTunnelingSessionCoordinator {

    enum State: Equatable {
        case stopped
        case starting
        case running
        case stopping

        var isUserVisiblyActive: Bool {
            switch self {
            case .running, .starting: return true
            case .stopped, .stopping: return false
            }
        }
    }

    private(set) var state: State = .stopped

    @ObservationIgnored private let split: SplitTunnelProviderManager
    @ObservationIgnored private let dns: DNSProxyProviderManager
    @ObservationIgnored private let dnsDaemonClient: DNSProxyDaemonClient
    @ObservationIgnored private let splitDaemonClient: SplitTunnelDaemonClient
    @ObservationIgnored private let oslog = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS",
        category: "session-coordinator"
    )

    /// Production leaves `state` at `.stopped` and lets `boot(with:)`
    /// reconcile against the live extensions; previews pass a fixed
    /// state to render the feature mid-session.
    init(
        split: SplitTunnelProviderManager,
        dns: DNSProxyProviderManager,
        dnsDaemonClient: DNSProxyDaemonClient,
        splitDaemonClient: SplitTunnelDaemonClient,
        state: State = .stopped
    ) {
        self.split = split
        self.dns = dns
        self.dnsDaemonClient = dnsDaemonClient
        self.splitDaemonClient = splitDaemonClient
        self.state = state
    }

    // MARK: - Boot Reconcile

    /// Called once after the extension gate clears. Adopts the live
    /// session status; honors `config.isEnabled` only when nothing is
    /// running.
    /// `freshConfig` is read AFTER the two loads rather than captured
    /// before them. The loads are real awaits, and an edit accepted in
    /// that window reaches disk while `reconfigure` refuses it — the
    /// state is not `.running` yet — so pushing the snapshot this
    /// method started with would hand both extensions the list the
    /// user just changed away from, and the realign would author the
    /// divergence it runs to repair.
    @discardableResult
    func boot(freshConfig: @MainActor () -> SplitTunnelingConfiguration) async -> ReconfigureOutcome {
        let booted = freshConfig()
        log("boot: start (persisted intent isEnabled=\(booted.isEnabled))")
        await split.load()
        await dns.load()
        let config = freshConfig()
        let splitStatus = split.sessionStatus
        log("boot: split.sessionStatus=\(splitStatus)")

        switch splitStatus {
        case .connected, .connecting:
            log("boot: SplitTunnel session already live → adopting .running")
            // The adopted session may be running a list this app never
            // sent it. SplitTunnel's bootstrap blob is written only by
            // `enable`, and `enable` is called only from `start`, so an
            // extension that respawned after the last start came up
            // with whatever was current at THAT moment. Nothing else
            // repaired it: `reconfigure` pushes on a user edit and
            // nowhere else, so the divergence lasted until the user
            // happened to touch the list again — which is to say, on a
            // machine nobody edits, forever.
            //
            // Deliberately NOT `reconfigure`: that also persists the
            // DNS `providerConfiguration`, and a boot has no business
            // writing to the preference layer just to read it back.
            // Pushed BEFORE `state = .running` on purpose. Adopting
            // first would open a window where `reconfigure` passes its
            // `.running` guard and races these two writes over the same
            // two daemons — a repair arm that produces the divergence
            // it exists to close.
            let splitPush = await splitDaemonClient.applyConfig(config)
            let dnsRealign = await dnsDaemonClient.applyConfig(config)
            log("boot: realign push → SplitTunnel \(splitPush.label), DNSProxy \(dnsRealign.label)")
            state = .running
            // Reported, not just logged. A realign that did not land is
            // the same class `Push` was introduced for: the extensions
            // keep running the list from the last `start`, and ending
            // in os_log would be exactly the silence this campaign
            // removed everywhere else.
            return .pushed(split: splitPush, dns: dnsRealign)
        case .disconnected, .disconnecting, .invalid:
            if config.isEnabled {
                log("boot: persisted intent ON, no live session → start()")
                try? await start(with: config)
            } else {
                log("boot: persisted intent OFF → state = .stopped")
                state = .stopped
            }
            // Neither arm pushed: `start` carries the payload through
            // `enable`, and the OFF arm has nothing to deliver.
            return .notRunning
        }
    }

    // MARK: - Lifecycle

    /// Master toggle ON. Both managers register; SplitTunnel session
    /// starts via `startVPNTunnel`. DNSProxy stays "registered but
    /// lazy" — the OS spawns it when SplitTunnel routes a port-53
    /// flow to it. Failure rolls back to `.stopped`.
    func start(with config: SplitTunnelingConfiguration) async throws {
        switch state {
        case .running, .starting:
            log("start: already \(state) — no-op")
            return
        case .stopped, .stopping:
            break
        }
        log("start: enabling extensions (apps=\(config.apps.count), iface=\(config.interfaceSelection))")
        state = .starting
        do {
            try await dns.enable(with: config)
            log("start: DNSProxy registered")
            try await split.enable(with: config)
            log("start: SplitTunnel registered + tunnel started")
            state = .running
            log("start: state = .running")
        } catch {
            log("start: failed — \(error.localizedDescription); rolling back")
            state = .stopping
            try? await split.disable()
            try? await dns.disable()
            state = .stopped
            log("start: state = .stopped")
            throw error
        }
    }

    /// Master toggle OFF. SplitTunnel stops first so the port-53
    /// carve-out is gone before DNSProxy unwinds.
    func stop() async {
        switch state {
        case .stopped, .stopping:
            log("stop: already \(state) — no-op")
            return
        case .running, .starting:
            break
        }
        log("stop: disabling extensions")
        state = .stopping
        try? await split.disable()
        log("stop: SplitTunnel disabled")
        try? await dns.disable()
        log("stop: DNSProxy disabled")
        state = .stopped
        log("stop: state = .stopped")
    }

    // MARK: - Uninstall

    /// Uninstall-path cleanup: stops a running session, then deletes
    /// both proxy preference entries. Best-effort by design — a
    /// survivor is inert without its extension, and the next enable
    /// replaces it wholesale.
    func purgeForUninstall() async {
        await stop()
        await split.remove()
        await dns.remove()
        log("purgeForUninstall: proxy preference entries removed")
    }

    /// What a live config change actually did. The caller needs the two
    /// verdicts separately because they fail into different worlds: a
    /// SplitTunnel push that did not land leaves listed apps inside the
    /// tunnel, while a DNSProxy push that did not land leaves their DNS
    /// going to the tunnel's resolver — the asymmetric routing this
    /// architecture exists to prevent.
    ///
    /// `.notRunning` is not a failure and not a success: the payload is
    /// on disk and the next `start` carries it. It is reported rather
    /// than swallowed because the window it names is reachable — a user
    /// editing the list while the feature is still coming up lands here
    /// and nothing tells them their edit did not reach the extensions.
    enum ReconfigureOutcome: Equatable {
        case notRunning
        case pushed(split: ProxyConfigDaemonClient.Push, dns: ProxyConfigDaemonClient.Push)

        /// True only when BOTH extensions answered yes. `.unreachable`
        /// is deliberately not counted as landed even though the push
        /// may have arrived, because a caller that reports state must
        /// not claim what it cannot read.
        var bothLanded: Bool {
            if case .pushed(let split, let dns) = self { return split == .done && dns == .done }
            return false
        }
    }

    /// Live config change. App pushes the new payload to both
    /// extensions independently via XPC `applyConfig` — SplitTunnel
    /// and DNSProxy each through their own daemon client.
    /// `dns.enable` is also called to persist the fresh
    /// `providerConfiguration` so future bootstraps read the latest
    /// blob. No-op when stopped.
    func reconfigure(with config: SplitTunnelingConfiguration) async -> ReconfigureOutcome {
        guard state == .running else {
            log("reconfigure: state=\(state) → no push (config persisted, applied on next start)")
            return .notRunning
        }
        log("reconfigure: XPC applyConfig → SplitTunnel")
        let split = await splitDaemonClient.applyConfig(config)
        log("reconfigure: SplitTunnel applyConfig \(split.label)")

        log("reconfigure: XPC applyConfig → DNSProxy")
        let dnsPush = await dnsDaemonClient.applyConfig(config)
        log("reconfigure: DNSProxy applyConfig \(dnsPush.label)")

        try? await dns.enable(with: config)
        log("reconfigure: DNSProxy providerConfiguration persisted")
        return .pushed(split: split, dns: dnsPush)
    }

    // MARK: - Logging

    private func log(_ message: String) {
        os_log("%{public}@", log: oslog, type: .default, message)
    }
}
