import Foundation
import NetworkExtension

// MARK: - Activation & Deactivation

extension TunnelsManager {

    func startActivation(of tunnel: TunnelContainer) {
        // Grant only on an ACCEPTED intent: a duplicate start on a
        // non-inactive tunnel is a no-op and must not re-arm the
        // revive mid-attempt.
        guard tunnel.status == .inactive else { return }
        // A newer intent ANYWHERE withdraws every older pending
        // revive first — reviving tunnel A after the user chose B
        // would override the freshest intent with a stale one.
        for other in tunnels {
            other.respawnReviveConsumed = true
            other.respawnReviveTask?.cancel()
            other.respawnReviveTask = nil
        }
        // Then this fresh intent grants its one revive. The revive
        // re-enters through `beginActivation` below this door, so a
        // revived attempt can never re-grant itself into a loop.
        tunnel.respawnReviveConsumed = false
        beginActivation(of: tunnel)
    }

    /// Everything the public door does except granting the respawn
    /// revive: exclusive-slot queueing, the disarm-others sweep, and
    /// rung 0. The disconnect observer's one-shot revive enters here.
    func beginActivation(of tunnel: TunnelContainer) {
        guard tunnel.status == .inactive else { return }

        if let activeTunnel = tunnels.first(where: { $0.status != .inactive && $0.status != .waiting }) {
            if let previousWaiting = waitingTunnel, previousWaiting.id != tunnel.id {
                previousWaiting.status = .inactive
            }
            tunnel.status = .waiting
            waitingTunnel = tunnel
            startDeactivation(of: activeTunnel)
            return
        }

        // Disarm every other tunnel's recovery rule first — recovery
        // belongs to the tunnel being activated now
        tunnels.filter { $0.id != tunnel.id && $0.isActivateOnDemandEnabled }.forEach { other in
            other.tunnelProvider.isOnDemandEnabled = false
            other.tunnelProvider.savePreferences { _ in }
        }

        startActivation(of: tunnel, at: 0)
    }

    func startDeactivation(of tunnel: TunnelContainer) {
        // A stop is the withdrawal of the intent that granted the
        // revive: spend it and cancel any pending one BEFORE any
        // async window (the armed stop's disarm save below suspends)
        // can let a spontaneous drop race a revive up against the
        // user's explicit stop.
        tunnel.respawnReviveConsumed = true
        tunnel.respawnReviveTask?.cancel()
        tunnel.respawnReviveTask = nil
        guard tunnel.status != .inactive && tunnel.status != .deactivating else { return }

        // A waiting tunnel has not started yet: toggling it off cancels
        // the queued activation. Sending stop to a session the system
        // never brought up draws no status callback, so it would strand
        // in `.deactivating` — clear the queue slot and return to idle.
        if tunnel.status == .waiting {
            if waitingTunnel?.id == tunnel.id { waitingTunnel = nil }
            tunnel.status = .inactive
            return
        }

        // Stand the recovery rule down first — with it armed, the
        // system would reconnect the moment the tunnel drops.
        if tunnel.isActivateOnDemandEnabled {
            tunnel.tunnelProvider.isOnDemandEnabled = false
            Task {
                do {
                    // A remove() can land while this save is queued —
                    // persisting then would re-mint the just-removed
                    // entry as a zombie in the system store. The list
                    // is the liveness authority: a container no
                    // longer listed has nothing left to persist.
                    guard tunnels.contains(where: { $0.id == tunnel.id }) else { return }
                    try await tunnel.tunnelProvider.savePreferences()
                    performDeactivation(of: tunnel)
                } catch {
                    // The tunnel keeps running and stays armed — a
                    // fact, not a choice: the stop request could not
                    // be persisted. Surface it instead of pretending.
                    tunnel.lastActivationError = .savingFailed(systemError: error)
                }
            }
        } else {
            performDeactivation(of: tunnel)
        }
    }

    /// Uninstall-path sweep: stands every tunnel's recovery rule down
    /// before the extensions go, so the system does not fight the
    /// teardown by reviving a tunnel mid-deactivation — and the
    /// entries the flow deliberately leaves in place (custody rows
    /// keep theirs as the anchor for their broken payloads) never
    /// carry an armed rule into the extension-less void. Best-effort,
    /// like the rest of the uninstall path.
    func disarmAllRecovery() async {
        // The sweep also voids every pending revive — a delayed
        // re-activation firing behind a green "armed-count=0" would
        // falsify the sweep a moment after it reported clean.
        for tunnel in tunnels {
            tunnel.respawnReviveConsumed = true
            tunnel.respawnReviveTask?.cancel()
            tunnel.respawnReviveTask = nil
        }
        for tunnel in tunnels where tunnel.isActivateOnDemandEnabled {
            tunnel.tunnelProvider.isOnDemandEnabled = false
            try? await tunnel.tunnelProvider.savePreferences()
        }
    }

    // MARK: - Private

    /// The recovery rule: one connect-on-any-network on-demand rule,
    /// armed on every activation that passes the foreign-slot
    /// pre-flight. There is no user-facing switch — starting a tunnel
    /// is the recovery intent, stopping it withdraws it
    /// (`startDeactivation` disarms before it stops). The rule also
    /// stands down without a stop when another local user's session
    /// is proven to hold the slot: the collision belts here and the
    /// connection gate's engage sweep — an armed rule against an
    /// occupied slot only feeds the cross-user fight.
    private static func armRecovery(on provider: TunnelProviding) {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        provider.onDemandRules = [rule]
        provider.isOnDemandEnabled = true
    }

    /// Stands the recovery rule down and persists it. Two caller
    /// families: the give-up paths that failed *locally* — a config
    /// that cannot load, or whose `startTunnel` throws, would fail the
    /// same way on every system-initiated on-demand retry, so leaving
    /// it armed is a loop trap — and the collision paths, where a
    /// proven foreign slot holder makes our armed rule pure fuel for
    /// the cross-user fight. A timeout or a dropped session with no
    /// holder in sight is the opposite case: that is the transient
    /// condition the recovery rule exists to ride out, so those paths
    /// leave it armed on purpose.
    private static func disarmRecovery(on provider: TunnelProviding) async {
        provider.isOnDemandEnabled = false
        try? await provider.savePreferences()
    }

    func startActivation(of tunnel: TunnelContainer, at retryIndex: Int) {
        guard retryIndex < maxRetries else {
            tunnel.isAttemptingActivation = false
            tunnel.activationTask?.cancel()
            tunnel.activationTask = nil
            tunnel.status = .inactive
            // The ladder ran out without the system ever reporting
            // connected or disconnected — there is no terminal system
            // error to show, only the timeout itself (a one-time stale
            // rung may have thrown and been reloaded past; a repeat
            // never reaches here, it exits terminal below). Recovery
            // stays armed on purpose: a timeout is transient (no network
            // or an unreachable server), exactly what on-demand rides out.
            tunnel.lastActivationError = .retryLimitReached(
                lastSystemError: TunnelsManager.noSystemDetail(LocalizationManager.shared.t("error_detail_timeout")))
            // A give-up path like the others: a queued tunnel takes the
            // turn of the one that just failed. Unlike the `.disconnected`
            // observer, these direct exits draw no status callback, so
            // the hand-off has to be made here.
            activateWaitingTunnelIfNeeded()
            return
        }

        if retryIndex == 0 {
            tunnel.status = .activating
            tunnel.lastActivationError = nil
        }

        tunnel.isAttemptingActivation = true
        let attemptId = UUID().uuidString
        tunnel.activationAttemptId = attemptId

        Task {
            // Pre-flight, first attempt only: when another local
            // user's session holds the system's one VPN slot, fail
            // fast and clean — no enable, no armed recovery rule, no
            // retry ladder. Saving an armed connect-on-any-network
            // rule against an occupied slot is what feeds the
            // cross-user on-demand fight; the honest outcome is the
            // gate's message, not eight doomed attempts. The
            // optimistic `.activating` above keeps the toggle honest
            // while the verdict (two vault reads) is fetched.
            // The verdict rides a tight deadline here: in a vault
            // respawn window the reads hang to their 5s transport
            // timeouts, and rung 0 sitting behind that is pure delay —
            // past the deadline the state is unverifiable, and
            // unverifiable already answers `.free`.
            if retryIndex == 0, case .heldByForeign = await foreignSlotVerdict(within: 2) {
                guard tunnel.activationAttemptId == attemptId,
                      tunnel.status == .activating else { return }
                tunnel.isAttemptingActivation = false
                tunnel.status = .inactive
                tunnel.lastActivationError = .foreignSlotHolder
                activateWaitingTunnelIfNeeded()
                return
            }
            // Re-guard BOTH facts after the verdict await: the user
            // may have toggled off (or handed the turn to a queued
            // tunnel) while the evidence was fetched. A toggle-off
            // does not touch the attemptId, so status must be checked
            // too — arming and starting past a cancel would raise the
            // tunnel against an explicit stop and persist an armed
            // rule the user just withdrew.
            guard tunnel.activationAttemptId == attemptId,
                  tunnel.status == .activating || tunnel.status == .reasserting else { return }

            // Enable the manager and arm recovery in the same save. An
            // activated tunnel is one the user wants back: the system
            // restarts it whenever a network returns — across reboots
            // and app termination included.
            tunnel.tunnelProvider.isEnabled = true
            Self.armRecovery(on: tunnel.tunnelProvider)
            do {
                try await tunnel.tunnelProvider.savePreferences()
                guard tunnel.activationAttemptId == attemptId else { return }
                await self.doStartVPNTunnel(tunnel: tunnel, attemptId: attemptId, retryIndex: retryIndex)
            } catch {
                tunnel.isAttemptingActivation = false
                tunnel.status = .inactive
                tunnel.lastActivationError = .savingFailed(systemError: error)
                activateWaitingTunnelIfNeeded()
            }
        }
    }

    func doStartVPNTunnel(tunnel: TunnelContainer, attemptId: String, retryIndex: Int) async {
        do {
            try await tunnel.tunnelProvider.loadPreferences()
        } catch {
            tunnel.isAttemptingActivation = false
            tunnel.status = .inactive
            tunnel.lastActivationError = .loadingFailed(systemError: error)
            // Local failure — stand recovery down so the OS does not
            // keep relaunching a config that cannot load.
            await Self.disarmRecovery(on: tunnel.tunnelProvider)
            activateWaitingTunnelIfNeeded()
            return
        }

        guard tunnel.activationAttemptId == attemptId else { return }

        do {
            try tunnel.tunnelProvider.startTunnel()
        } catch {
            // A stale configuration is documented recovery, not a
            // terminal error: another process touched the entry
            // between our save and start, and the cure is reload +
            // retry. ONE chance per ladder, on the first rung only —
            // a config that is stale again after a reload is not
            // raced, it is broken, and it falls to the terminal path
            // below (which stands recovery down), so the ladder can
            // never loop re-arming a persistently stale entry.
            if retryIndex == 0,
               (error as? NEVPNError)?.code == .configurationStale,
               tunnel.activationAttemptId == attemptId,
               (try? await tunnel.tunnelProvider.loadPreferences()) != nil {
                // Re-guard after the reload roundtrip: a toggle-off or
                // a queued handoff during the await must win.
                guard tunnel.activationAttemptId == attemptId,
                      tunnel.status == .activating || tunnel.status == .reasserting else { return }
                startActivation(of: tunnel, at: retryIndex + 1)
                return
            }
            // Collision beats the generic story: `.configurationDisabled`
            // (and some plain start failures) are how an occupied slot
            // surfaces — when the classifier proves a foreign holder,
            // name it instead of printing the system's opaque line.
            // One re-guard after the verdict await covers both exits:
            // a user who cancelled mid-fetch keeps their cancel.
            let verdict = await foreignSlotVerdict()
            guard tunnel.activationAttemptId == attemptId,
                  tunnel.status == .activating || tunnel.status == .reasserting else { return }
            if case .heldByForeign = verdict {
                tunnel.isAttemptingActivation = false
                tunnel.status = .inactive
                tunnel.lastActivationError = .foreignSlotHolder
                await Self.disarmRecovery(on: tunnel.tunnelProvider)
                activateWaitingTunnelIfNeeded()
                return
            }
            tunnel.isAttemptingActivation = false
            tunnel.status = .inactive
            tunnel.lastActivationError = .startingFailed(systemError: error)
            // Local failure — stand recovery down so the OS does not
            // keep relaunching a tunnel whose start throws.
            await Self.disarmRecovery(on: tunnel.tunnelProvider)
            activateWaitingTunnelIfNeeded()
            return
        }

        // Retry task — if still activating after interval, retry
        tunnel.activationTask?.cancel()
        let tunnelId = tunnel.id
        tunnel.activationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.retryInterval ?? 5.0))
            } catch {
                return
            }
            guard let self,
                  let tunnel = self.tunnels.first(where: { $0.id == tunnelId }),
                  tunnel.activationAttemptId == attemptId else { return }
            if tunnel.status == .activating || tunnel.status == .reasserting {
                self.startActivation(of: tunnel, at: retryIndex + 1)
            }
        }
    }

    func performDeactivation(of tunnel: TunnelContainer) {
        tunnel.status = .deactivating
        tunnel.tunnelProvider.stopTunnel()
    }

    func activateWaitingTunnelIfNeeded() {
        guard let waitingTunnel else { return }
        self.waitingTunnel = nil
        guard waitingTunnel.status == .waiting else { return }
        startActivation(of: waitingTunnel, at: 0)
    }

    // MARK: - Reset (Layer-Level)

    /// Ask the extension to restart its tunnel layer (wstunnel +
    /// WireGuard in ghost mode, WireGuard alone in standalone) in
    /// place — the `utun` interface and its routes stay up, so
    /// nothing leaks out onto the physical NIC while the layer is
    /// rebuilt. Triggered by the user's "Reset Connection" button
    /// when the tunnel appears stuck.
    ///
    /// Extension uses opcode `3`; the handler replies only after the
    /// full stop/start sequence completes, so this wrapper returning
    /// means the layer has been rebuilt (the WireGuard handshake
    /// itself may still be settling).
    func resetConnection(of tunnel: TunnelContainer) async throws {
        guard tunnel.status == .active || tunnel.status == .reasserting else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try tunnel.tunnelProvider.sendProviderMessage(Data([3])) { _ in
                    continuation.resume()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
