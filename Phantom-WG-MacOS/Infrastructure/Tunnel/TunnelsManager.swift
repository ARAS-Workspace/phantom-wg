import Foundation
import AppKit
import NetworkExtension

/// Source of truth for the tunnel list. Owns the pairing between the
/// system's NetworkExtension preferences (identity-only projections)
/// and the extension's TunnelVault (the payloads): `reconcileFromVault`
/// restores vault payloads the system lost, drops system entries the
/// vault does not back, and realigns drifted projections —
/// `creatingIds` keeps a pass from minting an entry for a tunnel
/// mid-import, and the debounced refresh coalesces the system's
/// change-notification bursts into single reload+reconcile passes.
/// Activation lives in `TunnelsManager+Activation`: one active tunnel
/// at a time — a newly toggled tunnel waits out the previous one's
/// deactivation before it starts. Every activation also silently arms
/// the recovery rule (one connect-on-any-network on-demand rule): an
/// activated tunnel is one the user wants back, so the system revives
/// it across reboots, app termination, and network loss. Deactivation
/// stands the rule down, and activating one tunnel disarms every
/// other tunnel's rule.
@Observable
@MainActor
class TunnelsManager {

    var tunnels: [TunnelContainer] = []

    @ObservationIgnored private let providerFactory: TunnelProviderFactory
    @ObservationIgnored let vault: TunnelVaultClient
    @ObservationIgnored private var statusObservationToken: AnyObject?
    @ObservationIgnored private var configObservationToken: AnyObject?
    @ObservationIgnored private var foregroundObservationToken: AnyObject?

    /// Serializes reconcile passes. Creating an entry makes the system
    /// broadcast a configuration change, which reloads and reconciles
    /// again — the flag keeps those from interleaving and creating the
    /// same tunnel twice.
    @ObservationIgnored private var isReconciling = false

    /// Ids whose system entry is being written right now. An add puts
    /// the payload in the vault before `savePreferences` lands the
    /// entry, and a reconcile pass squeezing into that gap — off a
    /// change notification whose reload still read the old, emptier
    /// list — sees "payload with no entry" and mints a second one.
    /// Field-measured on a first import; this set forbids it.
    @ObservationIgnored private var creatingIds: Set<UUID> = []

    /// Coalesces the refresh triggers. The system announces one change
    /// as a burst of notifications more often than not, and a
    /// foreground return can land on top of them — while every pass
    /// costs a full vault read that wakes the extension. One trailing
    /// pass serves the whole burst; `isReconciling` guards overlap,
    /// this guards repetition.
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    @ObservationIgnored var waitingTunnel: TunnelContainer?

    // Activation retry pacing (consumed by TunnelsManager+Activation)
    let retryInterval: TimeInterval = 5.0
    let maxRetries: Int = 8

    // MARK: - Factory

    static func create(vault: TunnelVaultClient) async throws -> TunnelsManager {
        let factory = RealTunnelProviderFactory()
        let providers = try await factory.loadAllFromPreferences()
        return TunnelsManager(tunnelProviders: providers, providerFactory: factory, vault: vault)
    }

    init(
        tunnelProviders: [TunnelProviding],
        providerFactory: TunnelProviderFactory = RealTunnelProviderFactory(),
        vault: TunnelVaultClient
    ) {
        self.providerFactory = providerFactory
        self.vault = vault
        tunnels = Self.sortedByCreatedAt(tunnelProviders.map { TunnelContainer(tunnel: $0) })
        startObservingTunnelStatuses()
        startObservingTunnelConfigurations()
        startObservingForeground()
    }

    /// Newest first — tunnels without a persisted `createdAt` fall back
    /// to `.distantPast` so they sort below freshly-created ones.
    static func sortedByCreatedAt(_ list: [TunnelContainer]) -> [TunnelContainer] {
        list.sorted {
            let lhs = $0.identity?.createdAt ?? .distantPast
            let rhs = $1.identity?.createdAt ?? .distantPast
            return lhs > rhs
        }
    }

    deinit {
        pendingRefresh?.cancel()
        if let token = statusObservationToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = configObservationToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = foregroundObservationToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - CRUD

    func add(config: TunnelConfig) async throws -> TunnelContainer {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw TunnelManagementError.tunnelInvalidName
        }
        if tunnels.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw TunnelManagementError.tunnelAlreadyExistsWithThatName
        }

        try await purgeVaultDuplicates(of: config)

        // From the vault write until the entry lands, this id is
        // reconcile's blind spot — mark it in flight.
        creatingIds.insert(config.id)
        defer { creatingIds.remove(config.id) }

        // Secrets first. A tunnel entry whose vault payload is missing
        // cannot start, so the vault write gates the whole operation —
        // and a failure here leaves the system exactly as it was.
        guard await vault.store(config) else {
            throw TunnelManagementError.vaultUnavailable
        }

        do {
            return try await createEntry(for: config)
        } catch {
            // Roll the vault back so a failed add leaves no orphaned
            // secrets behind.
            await vault.delete(id: config.id)
            throw error
        }
    }

    // MARK: - Reconcile

    /// Makes the system store agree with the vault, in both
    /// directions, because the vault is the source of truth: it holds
    /// each tunnel's whole configuration and outlives what the system
    /// keeps — macOS drops a tunnel's NetworkExtension configuration
    /// when its provider extension is uninstalled.
    ///
    /// A payload with no system entry is recreated, unprompted: the
    /// user has nothing to decide, the tunnel exists and the system
    /// simply forgot it. An entry with no payload is removed just as
    /// quietly — it cannot start, and telling the operator to repair
    /// something that is by definition unrepairable is worse than
    /// clearing it away. Nothing is destroyed by that removal: the
    /// entry pointed at a payload that is already gone. And a
    /// projection that stopped matching its payload — a name or mode
    /// the system store missed — is rewritten in place, the vault's
    /// version winning.
    ///
    /// Both directions rest on the vault having actually answered. A
    /// vault that cannot be reached teaches us nothing, and acting on
    /// that silence would delete every tunnel on the machine, so the
    /// pass simply does not run.
    @discardableResult
    func reconcileFromVault() async -> Int {
        // Idempotent by construction — it only creates entries the
        // vault backs and the system lacks, only removes entries the
        // vault does not back, and rewrites a projection only when it
        // differs, so a second pass over an unchanged world does
        // nothing. The flag is about overlap, not
        // repetition: a pass in flight must finish before the next one
        // reads the list it is still adding to.
        guard !isReconciling else { return 0 }
        isReconciling = true
        defer { isReconciling = false }

        guard case .configs(let payloads) = await vault.readAll() else {
            NSLog("[vault] reconcile skipped — the vault did not answer")
            return 0
        }

        await dropEntriesWithoutPayload(vaultIds: Set(payloads.map(\.id)))

        let known = Set(tunnels.map(\.id))
        let missing = payloads
            .filter { !known.contains($0.id) && !creatingIds.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }

        var restored = 0
        for config in missing {
            // `known` is a snapshot. An import finishing mid-pass — or
            // a bulk answer that carried the same id twice — would land
            // a config here whose tunnel already exists, and creating a
            // second entry for the same id is the one thing this pass
            // must never do. The live list is the authority.
            guard !tunnels.contains(where: { $0.id == config.id }) else { continue }

            // Names stay unique here too. Import and edit both refuse
            // a duplicate name, so reconcile must not be the one path
            // that manufactures one — a second tunnel with the same
            // name is indistinguishable to the operator and collides
            // in the name-keyed accessibility identifiers. The
            // payload is left in the vault rather than deleted:
            // renaming the tunnel that holds the name frees it, and
            // the next launch brings this one back.
            let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tunnels.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                NSLog("[vault] reconcile skipped \(config.id): a tunnel named '\(name)' already exists")
                continue
            }

            do {
                _ = try await createEntry(for: config)
                restored += 1
            } catch {
                // The payload stays put; the next launch tries again.
                NSLog("[vault] reconcile failed for \(config.id): \(error.localizedDescription)")
            }
        }

        await realignDriftedProjections(with: payloads)

        if restored > 0 {
            NSLog("[vault] reconcile restored \(restored) tunnel(s) the system had lost")
        }
        return restored
    }

    /// Realigns entries whose projection no longer matches their
    /// payload — the drift `modify` leaves behind when the vault write
    /// lands and the preference save fails. The vault's version wins:
    /// name and mode are rewritten onto the system entry in place.
    ///
    /// `createdAt` is deliberately not compared: nothing can change
    /// it, and the two stores round-trip the date through different
    /// epochs, so exact equality would misfire on precision noise and
    /// turn every pass into a save. Active tunnels are left alone,
    /// as everywhere in this pass — the drift waits for the session
    /// to end. A realign that would collide with another tunnel's
    /// name is skipped the same way a restore would be.
    private func realignDriftedProjections(with payloads: [TunnelConfig]) async {
        for config in payloads {
            guard let tunnel = tunnels.first(where: { $0.id == config.id }),
                  tunnel.status == .inactive,
                  let projected = tunnel.tunnelProvider.tunnelIdentity,
                  projected.name != config.name || projected.isGhost != config.isGhostMode
            else { continue }

            let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tunnels.contains(where: {
                $0.id != config.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                NSLog("[vault] reconcile skipped realigning \(config.id): a tunnel named '\(name)' already exists")
                continue
            }

            tunnel.tunnelProvider.localizedDescription = config.name
            tunnel.tunnelProvider.configure(with: config.identity)
            do {
                try await tunnel.tunnelProvider.savePreferences()
                try await tunnel.tunnelProvider.loadPreferences()
                tunnel.name = config.name
                NSLog("[vault] reconcile realigned \(config.id): the projection had gone stale")
            } catch {
                NSLog("[vault] reconcile could not realign \(config.id): \(error.localizedDescription)")
            }
        }
    }

    /// Removes system entries the vault does not back. Such an entry
    /// is a pointer to nothing: it cannot start, and no repair exists
    /// for it, so it is cleared instead of being shown as a fault.
    ///
    /// Two guards keep this from ever removing something real. A
    /// tunnel that is not idle is left alone — the running session
    /// owns its configuration and this is no moment to pull the entry
    /// out from under it. And every candidate is confirmed with its
    /// own read: the bulk answer is a snapshot, and a tunnel imported
    /// while this pass was in flight would look absent in it.
    private func dropEntriesWithoutPayload(vaultIds: Set<UUID>) async {
        for tunnel in tunnels where !vaultIds.contains(tunnel.id) {
            guard tunnel.status == .inactive else { continue }
            guard case .missing = await vault.read(id: tunnel.id) else { continue }

            do {
                try await tunnel.tunnelProvider.removePreferences()
                tunnels.removeAll { $0.id == tunnel.id }
                NSLog("[vault] dropped system entry \(tunnel.id) — the vault holds no payload for it")
            } catch {
                NSLog("[vault] could not drop system entry \(tunnel.id): \(error.localizedDescription)")
            }
        }
    }

    /// Drops any *other* payload that already claims this tunnel's
    /// name. Names are unique among listed tunnels, but a payload can
    /// outlive its entry — and one of those, holding a name the user
    /// is now reusing, would otherwise sit in the vault forever:
    /// reconcile refuses to restore it (the name is taken) and nothing
    /// else ever looks at it. Writing the name is the moment the user
    /// says which tunnel owns it, so that is where the old claim goes.
    ///
    /// A vault that cannot answer aborts the write instead of being
    /// skipped: letting a write proceed past an unanswered dedup is
    /// the one way a name collision can ever be born.
    private func purgeVaultDuplicates(of config: TunnelConfig) async throws {
        let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard case .configs(let payloads) = await vault.readAll() else {
            throw TunnelManagementError.vaultUnavailable
        }

        for other in payloads where other.id != config.id {
            let otherName = other.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard otherName.caseInsensitiveCompare(name) == .orderedSame else { continue }
            await vault.delete(id: other.id)
            NSLog("[vault] dropped stale payload \(other.id) that claimed the name '\(name)'")
        }
    }

    /// Creates and persists the system entry for a config, then adds
    /// it to the list. Shared by `add` and the reconcile restore path.
    private func createEntry(for config: TunnelConfig) async throws -> TunnelContainer {
        let provider = providerFactory.makeProvider()
        provider.localizedDescription = config.name
        provider.isEnabled = true
        provider.configure(with: config.identity)

        do {
            try await provider.savePreferences()
            try await provider.loadPreferences()
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnAddTunnel(systemError: error)
        }

        let tunnel = TunnelContainer(tunnel: provider)
        tunnels.append(tunnel)
        tunnels = Self.sortedByCreatedAt(tunnels)
        return tunnel
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

        try await purgeVaultDuplicates(of: config)

        // Same ordering as `add`. If the preference save fails after
        // this, the vault holds the edit while the identity projection
        // stays stale — the tunnel still starts from the new payload,
        // and the next reconcile pass realigns the projection.
        guard await vault.store(config) else {
            throw TunnelManagementError.vaultUnavailable
        }

        tunnel.tunnelProvider.localizedDescription = name
        tunnel.tunnelProvider.isEnabled = true
        tunnel.tunnelProvider.configure(with: config.identity)

        do {
            try await tunnel.tunnelProvider.savePreferences()
            try await tunnel.tunnelProvider.loadPreferences()
        } catch {
            throw TunnelManagementError.vpnSystemErrorOnModifyTunnel(systemError: error)
        }

        tunnel.name = name
    }

    func remove(tunnel: TunnelContainer) async throws {
        // The payload goes first, and its failure stops everything.
        //
        // Removing the system entry first looks tidier but loses the
        // race with our own machinery: that removal makes the system
        // broadcast a configuration change, which reconciles, which
        // finds a payload with no entry and dutifully puts the entry
        // back. Taking the truth away first means every later pass
        // agrees the tunnel is gone. And if the vault cannot be
        // reached, refusing outright leaves the tunnel whole rather
        // than half-deleted.
        guard await vault.delete(id: tunnel.id) else {
            throw TunnelManagementError.vaultUnavailable
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
    }

    /// Empties the vault ahead of extension deactivation — the
    /// uninstall flow's first step, and ordered before it by force:
    /// the vault lives behind the tunnel extension, so once
    /// deactivation starts there is no XPC peer left to ask, which is
    /// exactly how payloads used to outlive the app. A vault that
    /// cannot be emptied stops the uninstall whole rather than letting
    /// it report clean while secrets stay behind.
    func purgeVault() async throws {
        guard await vault.purge() else {
            throw TunnelManagementError.vaultPurgeFailed
        }
    }

    /// Stand-in for the rare paths where the system hands us no error
    /// object; carries a localized description so the alert's `%@`
    /// slot stays honest instead of printing a fabricated code.
    /// Internal, not private: `TunnelsManager+Activation` shares it.
    static func noSystemDetail(_ description: String) -> NSError {
        NSError(
            domain: "PhantomWG",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
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
            let newStatus = TunnelStatus(from: systemStatus)
            tunnel.status = newStatus

            if newStatus == .inactive {
                activateWaitingTunnelIfNeeded()
            }
        }
    }

    // MARK: - Configuration Observation

    /// The system broadcasts this whenever any VPN configuration
    /// changes — including one deleted from System Settings while the
    /// app is running. Reloading refreshes the list; reconciling then
    /// puts back anything the vault still holds, which is what makes
    /// an out-of-band deletion self-healing.
    private func startObservingTunnelConfigurations() {
        configObservationToken = NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
    }

    /// Coming back to the foreground is the catch-all trigger: it
    /// covers any change that happened while the app was in the
    /// background without a notification reaching it. Same door as
    /// the configuration observer — one refresh semantic, coalesced.
    private func startObservingForeground() {
        foregroundObservationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
    }

    /// Trailing-edge debounce: a new trigger restarts the window, the
    /// pass runs once the burst goes quiet.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    private func reload() async {
        guard let providers = try? await providerFactory.loadAllFromPreferences() else { return }

        // Update existing tunnels, add new ones, remove deleted ones.
        // Matching goes by persisted identity, not manager instance —
        // `loadAllFromPreferences` hands back fresh objects every call,
        // and an instance comparison would discard the containers the
        // views are already holding, resetting their activation
        // bookkeeping mid-flight.
        var newTunnels: [TunnelContainer] = []

        for provider in providers {
            if let existing = tunnels.first(where: { $0.id == provider.tunnelIdentity?.id }) {
                existing.name = provider.localizedDescription ?? ""
                existing.refreshStatus()
                newTunnels.append(existing)
            } else {
                newTunnels.append(TunnelContainer(tunnel: provider))
            }
        }

        tunnels = Self.sortedByCreatedAt(newTunnels)

        // The list now mirrors the system store; put back whatever the
        // vault says should be in it.
        await reconcileFromVault()
    }
}
