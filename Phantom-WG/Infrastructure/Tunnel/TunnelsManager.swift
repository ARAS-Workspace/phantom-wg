import Foundation
import NetworkExtension

/// Source of truth for the tunnel list, over the system's
/// NetworkExtension preferences. iOS keeps a single enabled VPN
/// configuration per app, and everything here bends around that rule:
/// `isEnabled` is written only at activation — never on add/modify,
/// so an import cannot drop a running tunnel. Every activation also
/// silently arms the recovery rule (one connect-on-any-network
/// on-demand rule): an activated tunnel is one the user wants back,
/// so the system revives it across reboots, app termination, and
/// network loss. Deactivation stands the rule down, and activating
/// one tunnel disarms every other tunnel's rule. One tunnel runs
/// at a time, a newly toggled tunnel waiting out the active one's
/// deactivation. Containers pair with configurations by persisted
/// `TunnelConfig.id` (add is id-guarded, reload matches by identity),
/// so the system's change notifications can race an add without
/// duplicating rows. Secrets live in the Keychain; the preferences
/// carry only a persistent reference.
@Observable
@MainActor
class TunnelsManager {

    var tunnels: [TunnelContainer] = []

    @ObservationIgnored private let providerFactory: TunnelProviderFactory
    @ObservationIgnored private var statusObservationToken: AnyObject?
    @ObservationIgnored private var configObservationToken: AnyObject?
    @ObservationIgnored private var waitingTunnel: TunnelContainer?
    /// Names an `add` holds from its uniqueness check until the new
    /// container is listed, keyed by the configuration id. The check
    /// reads these too, so two adds of one name across the save's
    /// awaits cannot both pass it.
    @ObservationIgnored private var namesBeingListed: [UUID: String] = [:]

    // Activation pacing
    let retryInterval: TimeInterval = 5.0
    let maxRetries: Int = 8

    // MARK: - Factory

    static func create() async throws -> TunnelsManager {
        #if DEBUG && targetEnvironment(simulator)
        let factory: TunnelProviderFactory = SimulatedTunnelProviderFactory()
        #else
        let factory: TunnelProviderFactory = RealTunnelProviderFactory()
        #endif
        let providers = try await factory.loadAllFromPreferences()
        return TunnelsManager(tunnelProviders: providers, providerFactory: factory)
    }

    init(tunnelProviders: [TunnelProviding], providerFactory: TunnelProviderFactory = RealTunnelProviderFactory()) {
        self.providerFactory = providerFactory
        tunnels = Self.sortedByCreatedAt(tunnelProviders.map { TunnelContainer(tunnel: $0) })
        startObservingTunnelStatuses()
        startObservingTunnelConfigurations()
    }

    /// Newest first — tunnels without a persisted `createdAt` fall back
    /// to `.distantPast` so they sort below freshly-created ones.
    static func sortedByCreatedAt(_ list: [TunnelContainer]) -> [TunnelContainer] {
        list.sorted {
            let lhs = $0.tunnelConfig?.createdAt ?? .distantPast
            let rhs = $1.tunnelConfig?.createdAt ?? .distantPast
            return lhs > rhs
        }
    }

    deinit {
        if let token = statusObservationToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = configObservationToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - CRUD

    func add(config: TunnelConfig) async throws -> TunnelContainer {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TunnelManagementError.tunnelInvalidName
        }
        if tunnels.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            || nameIsBeingListed(name, besides: config.id) {
            throw TunnelManagementError.tunnelAlreadyExistsWithThatName
        }
        namesBeingListed[config.id] = name
        defer { namesBeingListed[config.id] = nil }

        let provider = providerFactory.makeProvider()
        provider.localizedDescription = name
        // Deliberately saved disabled: iOS keeps a single enabled VPN
        // configuration per app, so enabling a new one here would
        // disable — and disconnect — a currently running tunnel.
        // Activation enables the manager right before it starts.

        do {
            try provider.configure(with: config)
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnAddTunnel(systemError: error)
        }

        do {
            try await provider.savePreferences()
            try await provider.loadPreferences()
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnAddTunnel(systemError: error)
        }

        // The save above already fired `NEVPNConfigurationChange`, and
        // `reload()` can win the race during the awaits — putting its
        // own container for this configuration into the list first.
        // Appending unconditionally would then duplicate the ForEach
        // identity ("ID occurs multiple times").
        if let existing = tunnels.first(where: { $0.id == config.id }) {
            return existing
        }

        let tunnel = TunnelContainer(tunnel: provider)
        tunnels.append(tunnel)
        tunnels = Self.sortedByCreatedAt(tunnels)
        return tunnel
    }

    private func nameIsBeingListed(_ name: String, besides id: UUID) -> Bool {
        namesBeingListed.contains {
            $0.key != id && $0.value.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    func modify(tunnel: TunnelContainer, with config: TunnelConfig) async throws {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TunnelManagementError.tunnelInvalidName
        }
        if tunnels.contains(where: {
            $0.id != tunnel.id
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            throw TunnelManagementError.tunnelAlreadyExistsWithThatName
        }

        tunnel.tunnelProvider.localizedDescription = name
        // `isEnabled` is left untouched for the same reason as in
        // `add`: flipping it on while another tunnel runs would tear
        // that session down. Edits require an inactive tunnel, and
        // activation enables the manager itself.

        do {
            try tunnel.tunnelProvider.configure(with: config)
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnModifyTunnel(systemError: error)
        }

        do {
            try await tunnel.tunnelProvider.savePreferences()
            try await tunnel.tunnelProvider.loadPreferences()
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnModifyTunnel(systemError: error)
        }

        tunnel.name = name
    }

    func remove(tunnel: TunnelContainer) async throws {
        // Destroy config from Keychain (if underlying provider supports it)
        if let proto = tunnel.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol {
            proto.destroyConfigInKeychain()
        }

        do {
            try await tunnel.tunnelProvider.removePreferences()
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnRemoveTunnel(systemError: error)
        }

        if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            tunnels.remove(at: index)
        }

        if waitingTunnel?.id == tunnel.id {
            waitingTunnel = nil
        }

        // The removed tunnel may be the one a queued tunnel was waiting
        // behind.
        activateWaitingTunnelIfNeeded()
    }

    // MARK: - Activation

    func startActivation(of tunnel: TunnelContainer) {
        guard tunnel.status == .inactive else { return }

        // If another tunnel is already active, queue this one as waiting
        if let activeTunnel = tunnels.first(where: { $0.status != .inactive && $0.status != .waiting }) {
            // Reset previous waiting tunnel if any
            if let previousWaiting = waitingTunnel, previousWaiting.id != tunnel.id {
                previousWaiting.status = .inactive
            }
            tunnel.status = .waiting
            waitingTunnel = tunnel
            startDeactivation(of: activeTunnel)
            return
        }

        startActivation(of: tunnel, at: 0)
    }

    func startDeactivation(of tunnel: TunnelContainer) {
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
        // system would reconnect the moment the tunnel drops. What the
        // save answers decides what is *said*, never whether the stop
        // happens: the user asked for this tunnel to go down, and a rule
        // left standing is a sentence, not a veto. A refusal leaves the
        // store holding whatever it left — nothing here writes the flag
        // back on its behalf, the next load re-reads it.
        if tunnel.carriesRecoveryRule {
            tunnel.tunnelProvider.isOnDemandEnabled = false
            Task {
                do {
                    try await tunnel.tunnelProvider.savePreferences()
                } catch {
                    tunnel.lastActivationError = .stopDisarmRefused(systemError: error)
                }
                performDeactivation(of: tunnel)
            }
        } else {
            performDeactivation(of: tunnel)
        }
    }

    // MARK: - Private Activation

    /// The recovery rule: one connect-on-any-network on-demand rule,
    /// armed on every activation. There is no user-facing switch —
    /// starting a tunnel is the recovery intent, stopping it withdraws
    /// it (`startDeactivation` disarms before it stops).
    private static func armRecovery(on provider: TunnelProviding) {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        provider.onDemandRules = [rule]
        provider.isOnDemandEnabled = true
    }

    /// Recovery belongs to the tunnel being activated now, so every other
    /// tunnel's rule comes down first. The gate reads `carriesRecoveryRule`
    /// rather than the armed flag: a stand-down that was refused leaves the
    /// flag false with the rule still standing, and a flag-shaped filter
    /// walks past exactly that tunnel. A refusal is that tunnel's own
    /// sentence on its own row — it is not the one the user just started.
    ///
    /// The same save writes the other tunnel disabled. Its object still
    /// holds the enabled flag from its own activation, and the system
    /// keeps one enabled configuration: saving that flag would enable it
    /// again and disable the tunnel starting now, whichever save lands
    /// last.
    private func disarmOtherRecoveryRules(except tunnel: TunnelContainer) {
        tunnels.filter { $0.id != tunnel.id && $0.carriesRecoveryRule }.forEach { other in
            other.tunnelProvider.isOnDemandEnabled = false
            other.tunnelProvider.isEnabled = false
            Task {
                do {
                    try await other.tunnelProvider.savePreferences()
                } catch {
                    other.lastActivationError = .stopDisarmRefused(systemError: error)
                }
            }
        }
    }

    /// Stands the recovery rule down and persists it. Used only on the
    /// give-up paths that failed *locally* — a config that cannot load,
    /// or whose `startTunnel` throws, would fail the same way on every
    /// system-initiated on-demand retry, so leaving it armed is a loop
    /// trap. A timeout or a dropped session is the opposite case: that
    /// is the transient condition the recovery rule exists to ride out,
    /// so those paths leave it armed on purpose.
    ///
    /// Returns the error when the save was refused, `nil` when it landed.
    /// The give-up paths that call this already carry the user's answer —
    /// why the activation failed — so none of them replaces that sentence
    /// with the rule's fate. The refusal is handed back rather than
    /// swallowed so that choice is written down at the call site instead
    /// of hiding inside a `try?`.
    @discardableResult
    private static func disarmRecovery(on provider: TunnelProviding) async -> Error? {
        provider.isOnDemandEnabled = false
        do {
            try await provider.savePreferences()
            return nil
        } catch {
            return error
        }
    }

    private func startActivation(of tunnel: TunnelContainer, at retryIndex: Int) {
        guard retryIndex < maxRetries else {
            tunnel.isAttemptingActivation = false
            tunnel.activationTask?.cancel()
            tunnel.activationTask = nil
            tunnel.status = .inactive
            // Every attempt started without throwing and the system
            // never reported connected or disconnected — there is no
            // system error to show, only the timeout itself. Recovery
            // stays armed on purpose: a timeout is transient (no network
            // or an unreachable server), exactly what on-demand rides out.
            tunnel.lastActivationError = .retryLimitReached(
                lastSystemError: Self.noSystemDetail(LocalizationManager.shared.t("error_detail_timeout")))
            // A give-up path like the others: a queued tunnel takes the
            // turn of the one that just failed. Unlike the `.disconnected`
            // observer, these direct exits draw no status callback, so
            // the hand-off has to be made here.
            activateWaitingTunnelIfNeeded()
            return
        }

        if retryIndex == 0 {
            // Every entrance reaches rung 0, the queue hand-off included,
            // so the sweep lives here: recovery belongs to the tunnel
            // starting now.
            disarmOtherRecoveryRules(except: tunnel)
            tunnel.status = .activating
            tunnel.lastActivationError = nil
        }

        tunnel.isAttemptingActivation = true
        let attemptId = UUID().uuidString
        tunnel.activationAttemptId = attemptId

        // Enable the manager and arm recovery in the same save. An
        // activated tunnel is one the user wants back: the system
        // restarts it whenever a network returns — across reboots
        // and app termination included.
        tunnel.tunnelProvider.isEnabled = true
        Self.armRecovery(on: tunnel.tunnelProvider)
        Task {
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

    private func doStartVPNTunnel(tunnel: TunnelContainer, attemptId: String, retryIndex: Int) async {
        do {
            try await tunnel.tunnelProvider.loadPreferences()
        } catch {
            tunnel.isAttemptingActivation = false
            tunnel.status = .inactive
            tunnel.lastActivationError = .loadingFailed(systemError: error)
            // Local failure — stand recovery down so the OS does not
            // keep relaunching a config that cannot load. A refused
            // stand-down is not written over the loading failure: that
            // is the answer the user asked for.
            await Self.disarmRecovery(on: tunnel.tunnelProvider)
            activateWaitingTunnelIfNeeded()
            return
        }

        guard tunnel.activationAttemptId == attemptId else { return }

        do {
            try tunnel.tunnelProvider.startTunnel()
        } catch {
            tunnel.isAttemptingActivation = false
            tunnel.status = .inactive
            tunnel.lastActivationError = .startingFailed(systemError: error)
            // Local failure — stand recovery down so the OS does not
            // keep relaunching a tunnel whose start throws. A refused
            // stand-down is not written over the starting failure: that
            // is the answer the user asked for.
            await Self.disarmRecovery(on: tunnel.tunnelProvider)
            activateWaitingTunnelIfNeeded()
            return
        }

        // Start retry task
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

    private func performDeactivation(of tunnel: TunnelContainer) {
        tunnel.status = .deactivating
        tunnel.tunnelProvider.stopTunnel()
    }

    /// Stand-in for the rare paths where the system hands us no error
    /// object; carries a localized description so the alert's `%@`
    /// slot stays honest instead of printing a fabricated code.
    private static func noSystemDetail(_ description: String) -> NSError {
        NSError(
            domain: "PhantomWG",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    /// Hands the slot to the queued tunnel once it is free. The slot is
    /// dropped when the queued row is no longer listed; it is kept while
    /// another tunnel still holds a session.
    private func activateWaitingTunnelIfNeeded() {
        guard let waitingTunnel else { return }
        guard tunnels.contains(where: { $0 === waitingTunnel }) else {
            self.waitingTunnel = nil
            return
        }
        guard !tunnels.contains(where: {
            $0.id != waitingTunnel.id && $0.status != .inactive && $0.status != .waiting
        }) else { return }
        self.waitingTunnel = nil

        // Verify the waiting tunnel is still in waiting state
        guard waitingTunnel.status == .waiting else { return }

        startActivation(of: waitingTunnel, at: 0)
    }

    // MARK: - Status Observation

    private func startObservingTunnelStatuses() {
        statusObservationToken = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let tunnel = self.tunnels.first(where: { $0.tunnelProvider.matchesNotification(notification) })
                else { return }
                self.handleStatusChange(for: tunnel)
            }
        }
    }

    private func handleStatusChange(for tunnel: TunnelContainer) {
        let systemStatus = tunnel.tunnelProvider.connectionStatus

        // If we're attempting activation, interpret the status in that context
        if tunnel.isAttemptingActivation {
            switch systemStatus {
            case .connected:
                tunnel.isAttemptingActivation = false
                tunnel.activationTask?.cancel()
                tunnel.activationTask = nil
                tunnel.status = .active

            case .disconnected:
                tunnel.isAttemptingActivation = false
                tunnel.activationTask?.cancel()
                tunnel.activationTask = nil
                tunnel.status = .inactive

                if tunnel.lastActivationError == nil {
                    // The system dropped the session mid-activation.
                    // Its own record of why — the extension's start
                    // failure — beats any synthesized stand-in; the
                    // attemptId guard keeps a slow fetch from writing
                    // over a newer activation round.
                    let attemptId = tunnel.activationAttemptId
                    Task { @MainActor in
                        let systemError = await tunnel.tunnelProvider.fetchLastDisconnectError()
                        guard tunnel.activationAttemptId == attemptId,
                              tunnel.lastActivationError == nil else { return }
                        tunnel.lastActivationError = .failedWhileActivating(
                            systemError: systemError
                                ?? Self.noSystemDetail(LocalizationManager.shared.t("error_detail_session_ended")))
                    }
                }

                // This tunnel may be the one a queued tunnel was waiting
                // to replace; its failure is that tunnel's turn — the
                // same hand-off the non-attempting `.inactive` path does.
                activateWaitingTunnelIfNeeded()

            case .connecting:
                tunnel.status = .activating

            case .disconnecting:
                tunnel.status = .deactivating

            case .reasserting:
                tunnel.status = .reasserting

            default:
                break
            }
        } else {
            // Normal status tracking, through the gate that keeps a
            // queued row's turn.
            tunnel.refreshStatus()

            if tunnel.status == .inactive {
                activateWaitingTunnelIfNeeded()
            }
        }
    }

    // MARK: - Configuration Observation

    private func startObservingTunnelConfigurations() {
        configObservationToken = NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.reload()
            }
        }
    }

    private func reload() async {
        guard let providers = try? await providerFactory.loadAllFromPreferences() else { return }

        // Update existing tunnels, add new ones, remove deleted ones.
        // Matching goes by persisted identity, not manager instance —
        // `loadAllFromPreferences` hands back fresh objects every call,
        // and an instance comparison would discard the containers the
        // views are already holding (and race `add` into duplicates).
        var newTunnels: [TunnelContainer] = []

        for provider in providers {
            if let existing = tunnels.first(where: { $0.id == provider.tunnelConfig?.id }) {
                existing.name = provider.localizedDescription ?? ""
                existing.refreshStatus()
                newTunnels.append(existing)
            } else {
                newTunnels.append(TunnelContainer(tunnel: provider))
            }
        }

        tunnels = Self.sortedByCreatedAt(newTunnels)
        // A session that ended without a status notification is grounded
        // here; the queued row keeps its turn through the gate, and the
        // hand-off starts it once the slot is free.
        activateWaitingTunnelIfNeeded()
    }
}
